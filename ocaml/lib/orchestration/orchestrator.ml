(** One pure owner reduces timestamped observations and resource terminals. *)

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
      of the epoch-fenced startup read and every admitted cleanup job. *)

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

module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Clock : Clock.PURE)
    (Workspace : Workspace_manager.PURE)
    (Agent :
      Agent_runner.PURE
        with module Issue = Tracker.Issue
         and module Path = Workspace.Path
         and type workspace = Workspace.reference)
    (Config : Config_layer.PURE with type tracker = Tracker.binding) =
struct
  module Plan = Run_plan.Make (Tracker) (Workspace) (Agent) (Config)

  module Life =
    Issue_lifecycle.Make (Tracker) (Clock) (Workspace) (Agent) (Plan)

  module Observation = Agent_observation.Make (Clock) (Agent)

  let worker_run : Life.owned -> Run_id.t option = function
    | Life.Starting run -> Some (Agent.run_id (Plan.request (Life.plan run)))
    | Life.Active run -> Some (Agent.run_id (Plan.request (Life.plan run)))
    | Life.Stopping run -> Some (Agent.run_id (Plan.request (Life.plan run)))
    | Life.Waiting _ | Life.Refreshing _ | Life.Parked _ | Life.Cleaning _ ->
        None

  module Owner = struct
    type t = { lifecycle : Life.owned; observation : Observation.t option }
    type instant = Clock.instant

    type role =
      | Worker
      | Cleanup
      | Retry_waiting of Retry_id.t * instant
      | Retry_refreshing of Retry_id.t

    let issue value = Life.issue value.lifecycle

    let role value =
      match value.lifecycle with
      | Life.Starting _ | Life.Active _ | Life.Stopping _ -> Worker
      | Life.Cleaning _ -> Cleanup
      | Life.Waiting retry -> Retry_waiting (Life.retry_id retry, Life.due retry)
      | Life.Refreshing retry -> Retry_refreshing (Life.retry_id retry)
      | Life.Parked retry -> Retry_refreshing (Life.retry_id retry)
  end

  module Owners = Ownership.Make (Clock) (Owner)

  type config = Config.t
  type instant = Clock.instant
  type tracker_request = Tracker.request
  type tracker_reply = Tracker.reply
  type agent_request = Agent.request
  type agent_progress = Agent.progress
  type agent_completed = Agent.completed
  type workspace_cleanup = Workspace.cleanup

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

  type epoch = Count.t
  type cycle_id = Count.t
  type authority = { cycle_id : cycle_id; epoch : epoch }
  type boot = Reading of epoch | Removing of epoch
  type stage = Boot of boot | Online | Draining | Stopping_host

  type cycle =
    | Idle
    | Reconciling of authority
    | Validating of authority
    | Fetching of authority
    | Discarding

  type loading = Settled | Awaiting of Request_id.t
  type custody = Live | Canceling

  type reconcile_target =
    | Worker_target of Issue_id.t * Run_id.t
    | Retry_target of Issue_id.t * Retry_id.t

  type deferred = { original : Tracker.binding; target : reconcile_target }

  type purpose =
    | Startup_read
    | Reconcile of cycle_id * (Issue_id.t * Run_id.t) list
    | Preflight of cycle_id
    | Candidates of cycle_id
    | Retry_read of Issue_id.t * Retry_id.t
    | Continuation_read of Issue_id.t * Run_id.t * Turn_id.t
    | Deferred_reconcile of deferred
    | Remove of Issue_id.t
    | Reload

  type job = {
    epoch : epoch;
    purpose : purpose;
    custody : custody;
    deferred : deferred option;
  }

  type poll = { token : Request_id.t; due : instant }

  type state = {
    config : Config.reload;
    epoch : epoch;
    stage : stage;
    cycle : cycle;
    loading : loading;
    owned : Owners.t;
    jobs : job Request_id.Map.t;
    poll : poll option;
    requests : Request_id.Allocator.t;
    runs : Run_id.Allocator.t;
    retries : Retry_id.Allocator.t;
    cycles : Count.t;
    ended : Seconds.t;
    ended_usage : Usage.t;
    latest_rate_limits : Json.t option;
  }

  type event = { now : instant; input : input }
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

  let equal_epoch a b = Count.compare a b = 0
  let effective (state : state) = Config.effective state.config
  let policy (state : state) = Config.scheduling (effective state)
  let binding (state : state) = Config.tracker (effective state)

  let read_policy (state : state) =
    Tracker_read_policy.of_scheduling (policy state)

  let ready (state : state) =
    match state.loading with
    | Awaiting _ -> false
    | Settled -> (
        match Config.readiness state.config with
        | Config.Ready -> true
        | Config.Blocked _ -> false)

  let settled (state : state) =
    match state.loading with
    | Settled -> true
    | Awaiting _ -> false

  let online (state : state) =
    match state.stage with
    | Online -> true
    | Boot _ | Draining | Stopping_host -> false

  let unowned (state : state) =
    Issue_id.Set.is_empty (Owners.claimed state.owned)

  let owners (state : state) =
    Owners.fold
      (fun _ owner rows -> owner.Owner.lifecycle :: rows)
      state.owned []
    |> List.sort (fun a b ->
        Issue_id.compare (Issue.id (Life.issue a)) (Issue.id (Life.issue b)))

  let find_owner issue owned =
    Option.map (fun owner -> owner.Owner.lifecycle) (Owners.find issue owned)

  let observation state issue =
    Option.bind (Owners.find issue state.owned) (fun owner ->
        owner.Owner.observation)

  let put (state : state) lifecycle =
    let issue = Issue.id (Life.issue lifecycle) in
    let observation =
      match worker_run lifecycle with
      | None -> None
      | Some run -> (
          match Owners.find issue state.owned with
          | Some previous when worker_run previous.Owner.lifecycle = Some run ->
              previous.Owner.observation
          | None | Some _ ->
              let settings =
                match lifecycle with
                | Life.Starting value ->
                    Agent.agent (Plan.request (Life.plan value))
                | Life.Active value ->
                    Agent.agent (Plan.request (Life.plan value))
                | Life.Stopping value ->
                    Agent.agent (Plan.request (Life.plan value))
                | Life.Waiting _
                | Life.Refreshing _
                | Life.Parked _
                | Life.Cleaning _ -> assert false
              in
              Some (Observation.empty settings))
    in
    {
      state with
      owned = Owners.put { Owner.lifecycle; observation } state.owned;
    }

  let put_observation state issue observation =
    match Owners.find issue state.owned with
    | None -> state
    | Some owner ->
        {
          state with
          owned =
            Owners.put
              { owner with Owner.observation = Some observation }
              state.owned;
        }

  let remove (state : state) id =
    { state with owned = Owners.remove id state.owned }

  let fresh_request (state : state) =
    let token, requests = Request_id.Allocator.fresh state.requests in
    ({ state with requests }, token)

  let fresh_run (state : state) =
    let token, runs = Run_id.Allocator.fresh state.runs in
    ({ state with runs }, token)

  let fresh_retry (state : state) =
    let token, retries = Retry_id.Allocator.fresh state.retries in
    ({ state with retries }, token)

  let fresh_cycle (state : state) =
    let cycles = Count.add state.cycles Count.one in
    ({ state with cycles }, cycles)

  let add_job (state : state) id purpose =
    let job =
      { epoch = state.epoch; purpose; custody = Live; deferred = None }
    in
    { state with jobs = Request_id.Map.add id job state.jobs }

  let report issue diagnostic effects =
    Report (Lifecycle_failure (issue, diagnostic)) :: effects

  let worker_count (state : state) =
    Owners.fold
      (fun _ owner count ->
        match owner.Owner.lifecycle with
        | Life.Starting _ | Life.Active _ | Life.Stopping _ -> count + 1
        | Life.Waiting _ | Life.Refreshing _ | Life.Parked _ | Life.Cleaning _
          -> count)
      state.owned 0

  let state_count (state : state) key =
    Owners.fold
      (fun _ owner count ->
        match owner.Owner.lifecycle with
        | Life.Starting _ | Life.Active _ | Life.Stopping _ ->
            if String.equal key (Issue.state_key (Owner.issue owner)) then
              count + 1
            else count
        | Life.Waiting _ | Life.Refreshing _ | Life.Parked _ | Life.Cleaning _
          -> count)
      state.owned 0

  let slots (state : state) issue =
    worker_count state < Scheduling_policy.global_limit (policy state)
    && state_count state (Issue.state_key issue)
       < Scheduling_policy.state_limit (policy state) (Issue.state_key issue)

  let routable (state : state) issue =
    match Issue.routing issue with
    | Issue.Unroutable -> false
    | Issue.Dispatchable ->
        Scheduling_policy.Names.for_all
          (fun label -> List.exists (String.equal label) (Issue.labels issue))
          (Scheduling_policy.required_labels (policy state))

  let eligible (state : state) issue =
    match Scheduling_policy.classify (policy state) issue with
    | Scheduling_policy.Terminal | Scheduling_policy.Inactive -> false
    | Scheduling_policy.Active -> routable state issue

  let cancel_poll (state : state) effects =
    match state.poll with
    | None -> (state, effects)
    | Some poll ->
        ({ state with poll = None }, Cancel_poll poll.token :: effects)

  let arm_poll (state : state) due effects =
    let state, effects = cancel_poll state effects in
    let state, token = fresh_request state in
    ({ state with poll = Some { token; due } }, Arm_poll (token, due) :: effects)

  let finish_cycle (state : state) _now effects =
    ({ state with cycle = Idle }, effects)

  let has_job (state : state) predicate =
    Request_id.Map.exists (fun _ job -> predicate job.purpose) state.jobs

  let cycle_job = function
    | Reconcile _ | Preflight _ | Candidates _ -> true
    | Startup_read
    | Retry_read _
    | Continuation_read _
    | Deferred_reconcile _
    | Remove _
    | Reload -> false

  let for_cycle cycle = function
    | Reconcile (id, _) | Preflight id | Candidates id -> equal_epoch cycle id
    | Startup_read
    | Retry_read _
    | Continuation_read _
    | Deferred_reconcile _
    | Remove _
    | Reload -> false

  let issue_read issue = function
    | Reconcile (_, targets) ->
        List.exists (fun (id, _) -> Issue_id.equal id issue) targets
    | Retry_read (id, _) | Continuation_read (id, _, _) ->
        Issue_id.equal id issue
    | Deferred_reconcile
        { target = Worker_target (id, _) | Retry_target (id, _); _ } ->
        Issue_id.equal id issue
    | Startup_read | Preflight _ | Candidates _ | Remove _ | Reload -> false

  let continuation_job = function
    | Continuation_read _ | Deferred_reconcile _ -> true
    | Startup_read
    | Reconcile _
    | Preflight _
    | Candidates _
    | Retry_read _
    | Remove _
    | Reload -> false

  let needs_continuation state issue =
    Option.bind (observation state issue) Observation.need

  let cancel_jobs (state : state) predicate effects =
    List.fold_left
      (fun (state, effects) (id, job) ->
        match job.custody with
        | Canceling -> (state, effects)
        | Live ->
            if not (predicate job.purpose) then (state, effects)
            else
              let job = { job with custody = Canceling } in
              ( { state with jobs = Request_id.Map.add id job state.jobs },
                Cancel_request id :: effects ))
      (state, effects)
      (Request_id.Map.bindings state.jobs)

  let policy_job = function
    | Startup_read
    | Reconcile _
    | Candidates _
    | Retry_read _
    | Continuation_read _
    | Deferred_reconcile _ -> true
    | Preflight _ | Remove _ | Reload -> false

  let load_job = function
    | Preflight _ | Reload -> true
    | Startup_read
    | Reconcile _
    | Candidates _
    | Retry_read _
    | Continuation_read _
    | Deferred_reconcile _
    | Remove _ -> false

  let load_invalidates = function
    | Preflight _ | Reload | Candidates _ | Retry_read _ -> true
    | Startup_read
    | Reconcile _
    | Continuation_read _
    | Deferred_reconcile _
    | Remove _ -> false

  (* Effects use a reverse accumulator; state reservations precede each emit. *)
  let begin_load (state : state) purpose effects =
    let state, effects = cancel_jobs state load_job effects in
    let state, id = fresh_request state in
    let state = add_job state id purpose in
    ( { state with loading = Awaiting id },
      Load_workflow { id; file = Config.file (effective state) } :: effects )

  let begin_startup (state : state) effects =
    let state, id = fresh_request state in
    let state = add_job state id Startup_read in
    let request =
      Tracker.States
        {
          id;
          binding = binding state;
          policy = read_policy state;
          names =
            Scheduling_policy.Names.elements
              (Scheduling_policy.terminal (policy state));
        }
    in
    ( { state with stage = Boot (Reading state.epoch); cycle = Idle },
      Read_tracker request :: effects )

  let begin_candidates (state : state) (authority : authority) effects =
    let state, id = fresh_request state in
    let state = add_job state id (Candidates authority.cycle_id) in
    let request =
      Tracker.States
        {
          id;
          binding = binding state;
          policy = read_policy state;
          names =
            Scheduling_policy.Names.elements
              (Scheduling_policy.active (policy state));
        }
    in
    ({ state with cycle = Fetching authority }, Read_tracker request :: effects)

  let group_workers (state : state) =
    let add binding target groups =
      let rec insert = function
        | [] -> [ (binding, [ target ]) ]
        | (existing, targets) :: rest ->
            if Tracker.equal binding existing then
              (existing, target :: targets) :: rest
            else (existing, targets) :: insert rest
      in
      insert groups
    in
    List.fold_left
      (fun groups owner ->
        let add_run run =
          let plan = Life.plan run in
          let issue = Issue.id (Life.issue owner) in
          let waiting =
            match owner with
            | Life.Starting _ | Life.Active _ ->
                Option.is_some (needs_continuation state issue)
            | Life.Stopping _
            | Life.Waiting _
            | Life.Refreshing _
            | Life.Parked _
            | Life.Cleaning _ -> false
          in
          if waiting || has_job state (issue_read issue) then groups
          else
            add (Plan.binding plan)
              (issue, Agent.run_id (Plan.request plan))
              groups
        in
        match owner with
        | Life.Starting run -> add_run run
        | Life.Active run -> add_run run
        | Life.Stopping run -> add_run run
        | Life.Waiting _ | Life.Refreshing _ | Life.Parked _ | Life.Cleaning _
          -> groups)
      [] (owners state)

  let begin_cycle (state : state) effects =
    let state, cycle_id = fresh_cycle state in
    let authority = { cycle_id; epoch = state.epoch } in
    let state = { state with cycle = Reconciling authority } in
    List.fold_left
      (fun (state, effects) (original, targets) ->
        let targets = List.rev targets in
        let state, id = fresh_request state in
        let state = add_job state id (Reconcile (cycle_id, targets)) in
        let ids =
          List.fold_left
            (fun ids (issue, _) -> Issue_id.Set.add issue ids)
            Issue_id.Set.empty targets
        in
        let request =
          Tracker.Ids
            { id; binding = original; policy = read_policy state; ids }
        in
        (state, Read_tracker request :: effects))
      (state, effects) (group_workers state)

  let begin_preflight (state : state) (authority : authority) effects =
    let state = { state with cycle = Validating authority } in
    match state.loading with
    | Settled -> begin_load state (Preflight authority.cycle_id) effects
    | Awaiting id -> (
        match Request_id.Map.find_opt id state.jobs with
        | Some job ->
            let job = { job with purpose = Preflight authority.cycle_id } in
            ({ state with jobs = Request_id.Map.add id job state.jobs }, effects)
        | None -> begin_load state (Preflight authority.cycle_id) effects)

  let read_retry (state : state) issue token effects =
    let state, id = fresh_request state in
    let state = add_job state id (Retry_read (issue, token)) in
    let request =
      Tracker.Ids
        {
          id;
          binding = binding state;
          policy = read_policy state;
          ids = Issue_id.Set.singleton issue;
        }
    in
    (state, Read_tracker request :: effects)

  let refresh_waiting (state : state) issue retry effects =
    if has_job state (issue_read issue) then (state, effects)
    else
      let state = put state (Life.Refreshing (Life.refresh retry)) in
      read_retry state issue (Life.retry_id retry) effects

  let reread_parked (state : state) issue retry effects =
    let state = put state (Life.Refreshing (Life.reread retry)) in
    read_retry state issue (Life.retry_id retry) effects

  let wake_retries (state : state) now effects =
    match state.stage with
    | Boot _ | Draining | Stopping_host -> (state, effects)
    | Online ->
        if not (ready state) then (state, effects)
        else
          List.fold_left
            (fun (state, effects) owner ->
              let issue = Issue.id (Life.issue owner) in
              match owner with
              | Life.Waiting retry ->
                  if Clock.compare now (Life.due retry) < 0 then (state, effects)
                  else
                    refresh_waiting state issue retry
                      (Cancel_retry (issue, Life.retry_id retry) :: effects)
              | Life.Parked retry -> reread_parked state issue retry effects
              | Life.Starting _
              | Life.Active _
              | Life.Stopping _
              | Life.Refreshing _
              | Life.Cleaning _ -> (state, effects))
            (state, effects) (owners state)

  type stop_disposition = Retry_after_stop | Release | Cleanup

  (* A stalled continuation keeps its frozen authority until the old read joins. *)
  let defer_continuations state issue plan =
    let run = Agent.run_id (Plan.request plan) in
    let deferred =
      { original = Plan.binding plan; target = Worker_target (issue, run) }
    in
    let jobs =
      Request_id.Map.map
        (fun job ->
          match job.purpose with
          | Continuation_read (id, token, _)
            when Issue_id.equal issue id && Run_id.equal run token ->
              { job with deferred = Some deferred }
          | Startup_read
          | Reconcile _
          | Preflight _
          | Candidates _
          | Retry_read _
          | Continuation_read _
          | Deferred_reconcile _
          | Remove _
          | Reload -> job)
        state.jobs
    in
    { state with jobs }

  (* A canceled continuation may outlive its worker; its closure wakes only the
     matching due retry, after the retained read loses resource custody. *)
  let wake_closed_continuation state issue now effects =
    match (state.stage, find_owner issue state.owned) with
    | Online, Some (Life.Waiting retry)
      when ready state && Clock.compare now (Life.due retry) >= 0 ->
        refresh_waiting state issue retry effects
    | ( (Boot _ | Online | Draining | Stopping_host),
        ( None
        | Some
            ( Life.Starting _
            | Life.Active _
            | Life.Stopping _
            | Life.Waiting _
            | Life.Refreshing _
            | Life.Parked _
            | Life.Cleaning _ ) ) ) -> (state, effects)

  let stop_owner (state : state) owner reason disposition cancel effects =
    let issue = Issue.id (Life.issue owner) in
    let state =
      match (disposition, owner) with
      | Retry_after_stop, Life.Starting run ->
          defer_continuations state issue (Life.plan run)
      | Retry_after_stop, Life.Active run ->
          defer_continuations state issue (Life.plan run)
      | ( (Retry_after_stop | Release | Cleanup),
          ( Life.Starting _
          | Life.Active _
          | Life.Stopping _
          | Life.Waiting _
          | Life.Refreshing _
          | Life.Parked _
          | Life.Cleaning _ ) ) -> state
    in
    let state, effects =
      cancel_jobs state
        (function
          | Continuation_read (id, _, _) -> Issue_id.equal issue id
          | Startup_read
          | Reconcile _
          | Preflight _
          | Candidates _
          | Retry_read _
          | Deferred_reconcile _
          | Remove _
          | Reload -> false)
        effects
    in
    let refine run =
      match disposition with
      | Retry_after_stop -> run
      | Release -> Life.release_after_close run
      | Cleanup -> Life.clean_after_close run
    in
    match owner with
    | Life.Starting run ->
        let stopped = refine (Life.stop_starting run reason) in
        ( put state (Life.Stopping stopped),
          Stop_worker
            (issue, Agent.run_id (Plan.request (Life.plan run)), cancel)
          :: effects )
    | Life.Active run ->
        let stopped = refine (Life.stop_active run reason) in
        ( put state (Life.Stopping stopped),
          Stop_worker
            (issue, Agent.run_id (Plan.request (Life.plan run)), cancel)
          :: effects )
    | Life.Stopping run -> (put state (Life.Stopping (refine run)), effects)
    | Life.Waiting _ | Life.Refreshing _ | Life.Parked _ | Life.Cleaning _ ->
        (state, effects)

  let drain (state : state) stage reason cancel effects =
    let state, effects =
      cancel_poll { state with stage; cycle = Idle } effects
    in
    let state =
      {
        state with
        jobs =
          Request_id.Map.map
            (fun job -> { job with deferred = None })
            state.jobs;
      }
    in
    let state, effects =
      List.fold_left
        (fun (state, effects) owner ->
          let issue = Issue.id (Life.issue owner) in
          match owner with
          | Life.Starting _ | Life.Active _ | Life.Stopping _ ->
              stop_owner state owner reason Release cancel effects
          | Life.Waiting retry ->
              let _released = Life.release_waiting retry in
              ( remove state issue,
                Cancel_retry (issue, Life.retry_id retry) :: effects )
          | Life.Parked retry ->
              let _released = Life.release_parked retry in
              (remove state issue, effects)
          | Life.Refreshing _ | Life.Cleaning _ -> (state, effects))
        (state, effects) (owners state)
    in
    cancel_jobs state
      (function
        | Remove _ -> false
        | Startup_read
        | Reconcile _
        | Preflight _
        | Candidates _
        | Retry_read _
        | Continuation_read _
        | Deferred_reconcile _
        | Reload -> true)
      effects

  let reserve_cleanup (state : state) cleanup effects =
    let request = Life.cleanup_request cleanup in
    let issue = Workspace.issue_id request.Workspace.workspace in
    let state = put state (Life.Cleaning cleanup) in
    let state = add_job state request.Workspace.request_id (Remove issue) in
    (state, Remove_workspace request :: effects)

  let startup_issue (state : state) issue effects =
    let config = effective state in
    match
      Workspace.reference ~settings:(Config.workspace config)
        ~env:(Config.child_env config)
        ~scope:(Tracker.scope (Config.tracker config))
        ~issue_id:(Issue.id issue) ~identifier:(Issue.identifier issue)
    with
    | Error error -> (state, Report (Planning_failure (issue, error)) :: effects)
    | Ok workspace -> (
        let state, request_id = fresh_request state in
        let request = { Workspace.request_id; workspace } in
        match Life.clean_startup (Life.unclaimed issue) request with
        | Error diagnostic -> (state, report issue diagnostic effects)
        | Ok cleanup -> reserve_cleanup state cleanup effects)

  let replace_current (state : state) owner issue effects =
    match Life.replace_issue owner issue with
    | Ok owner -> (put state owner, effects)
    | Error diagnostic -> (state, report (Life.issue owner) diagnostic effects)

  let reconcile_one (state : state) (issue, run) reply effects =
    match find_owner issue state.owned with
    | None -> (state, effects)
    | Some owner -> (
        match worker_run owner with
        | None -> (state, effects)
        | Some current when not (Run_id.equal current run) -> (state, effects)
        | Some _ -> (
            match Issue_id.Map.find_opt issue reply with
            | None ->
                stop_owner state owner Stop_reason.Reconcile_missing Release
                  (Agent_runner.Cancel Agent_runner.Reconciliation) effects
            | Some refreshed -> (
                let state, effects =
                  replace_current state owner refreshed effects
                in
                let owner =
                  match find_owner issue state.owned with
                  | Some current -> current
                  | None -> owner
                in
                match
                  Scheduling_policy.classify (policy state) (Life.issue owner)
                with
                | Scheduling_policy.Terminal ->
                    stop_owner state owner Stop_reason.Reconcile_terminal
                      Cleanup (Agent_runner.Cancel Agent_runner.Reconciliation)
                      effects
                | Scheduling_policy.Inactive ->
                    stop_owner state owner Stop_reason.Reconcile_inactive
                      Release (Agent_runner.Cancel Agent_runner.Reconciliation)
                      effects
                | Scheduling_policy.Active ->
                    if routable state (Life.issue owner) then (state, effects)
                    else
                      stop_owner state owner Stop_reason.Reconcile_unroutable
                        Release
                        (Agent_runner.Cancel Agent_runner.Reconciliation)
                        effects)))

  let failure_due (state : state) now attempt =
    Clock.after now
      (Backoff.failure ~attempt
         ~cap:(Scheduling_policy.max_retry_delay (policy state)))

  let admit (state : state) issue now effects =
    let state, run = fresh_run state in
    let unclaimed = Life.unclaimed issue in
    match Plan.create (effective state) ~run ~issue ~attempt:Template.First with
    | Ok plan -> (
        match Life.start unclaimed plan ~now with
        | Error diagnostic -> (state, report issue diagnostic effects)
        | Ok starting ->
            ( put state (Life.Starting starting),
              Start_worker (Plan.request plan) :: effects ))
    | Error rejection -> (
        let state, retry_id = fresh_retry state in
        let due = failure_due state now Positive_count.first in
        let effects =
          Report (Planning_failure (issue, Plan.rejected_error rejection))
          :: effects
        in
        match Life.reject_start unclaimed rejection ~retry_id ~due with
        | Error diagnostic -> (state, report issue diagnostic effects)
        | Ok retry ->
            ( put state (Life.Waiting retry),
              Arm_retry (Issue.id issue, retry_id, due) :: effects ))

  let admit_candidates (state : state) reply now effects =
    Issue_id.Map.bindings reply
    |> List.map snd
    |> List.stable_sort Dispatch_order.dispatch
    |> List.fold_left
         (fun (state, effects) issue ->
           match find_owner (Issue.id issue) state.owned with
           | Some _ -> (state, effects)
           | None ->
               if eligible state issue && slots state issue then
                 admit state issue now effects
               else (state, effects))
         (state, effects)

  let park_closed (state : state) issue retry effects =
    let parked = Life.park (Life.settled retry) in
    let state = put state (Life.Parked parked) in
    match state.stage with
    | Online when ready state -> reread_parked state issue parked effects
    | Boot _ | Online | Draining | Stopping_host -> (state, effects)

  let discard_retry (state : state) issue token effects =
    match find_owner issue state.owned with
    | Some (Life.Refreshing retry)
      when Retry_id.equal token (Life.retry_id retry) -> (
        match state.stage with
        | Draining | Stopping_host ->
            let _released = Life.release_refreshed (Life.settled retry) in
            (remove state issue, effects)
        | Boot _ | Online -> park_closed state issue retry effects)
    | None
    | Some (Life.Starting _)
    | Some (Life.Active _)
    | Some (Life.Stopping _)
    | Some (Life.Waiting _)
    | Some (Life.Refreshing _)
    | Some (Life.Parked _)
    | Some (Life.Cleaning _) -> (state, effects)

  let terminal_retry (state : state) issue retry effects =
    let state, request_id = fresh_request state in
    match Life.terminal_retry retry ~request_id with
    | Life.Release _ -> (remove state issue, effects)
    | Life.Cleanup cleanup -> reserve_cleanup state cleanup effects

  let requeue (state : state) issue retry failure now effects =
    let state, retry_id = fresh_retry state in
    let attempt = Positive_count.next (Life.attempt retry) in
    let due = failure_due state now attempt in
    let waiting = Life.requeue retry failure ~retry_id ~due in
    ( put state (Life.Waiting waiting),
      Arm_retry (issue, retry_id, due) :: effects )

  let resume (state : state) issue retry now effects =
    let current = Life.issue (Life.Refreshing retry) in
    let refreshed = Life.settled retry in
    if not (slots state current) then
      requeue state issue refreshed Life.Slots_unavailable now effects
    else
      let state, run = fresh_run state in
      let attempt = Template.Follow_up (Life.attempt refreshed) in
      match Plan.create (effective state) ~run ~issue:current ~attempt with
      | Ok plan -> (
          match Life.resume refreshed plan ~now with
          | Ok starting ->
              ( put state (Life.Starting starting),
                Start_worker (Plan.request plan) :: effects )
          | Error diagnostic ->
              (* A broken port law cannot retain a resource-closed Refreshing. *)
              ( put state (Life.Parked (Life.park refreshed)),
                report current diagnostic effects ))
      | Error rejection -> (
          let state, retry_id = fresh_retry state in
          let attempt = Positive_count.next (Life.attempt refreshed) in
          let due = failure_due state now attempt in
          let effects =
            Report (Planning_failure (current, Plan.rejected_error rejection))
            :: effects
          in
          match Life.reject_resume refreshed rejection ~retry_id ~due with
          | Ok waiting ->
              ( put state (Life.Waiting waiting),
                Arm_retry (issue, retry_id, due) :: effects )
          | Error diagnostic ->
              ( put state (Life.Parked (Life.park refreshed)),
                report current diagnostic effects ))

  let finish_retry (state : state) issue token reply now effects =
    match find_owner issue state.owned with
    | Some (Life.Refreshing retry)
      when Retry_id.equal token (Life.retry_id retry) -> (
        match reply with
        | Error error ->
            requeue state issue (Life.settled retry) (Life.Tracker_failed error)
              now
              (Report
                 (Issue_tracker_failure
                    (Life.issue (Life.Refreshing retry), error))
              :: effects)
        | Ok issues -> (
            match Issue_id.Map.find_opt issue issues with
            | None ->
                if not (ready state) then park_closed state issue retry effects
                else
                  let _released = Life.release_refreshed (Life.settled retry) in
                  (remove state issue, effects)
            | Some current -> (
                let state, effects =
                  replace_current state (Life.Refreshing retry) current effects
                in
                match find_owner issue state.owned with
                | Some (Life.Refreshing retry) -> (
                    if not (ready state) then
                      park_closed state issue retry effects
                    else
                      match
                        Scheduling_policy.classify (policy state)
                          (Life.issue (Life.Refreshing retry))
                      with
                      | Scheduling_policy.Terminal ->
                          terminal_retry state issue (Life.settled retry)
                            effects
                      | Scheduling_policy.Inactive ->
                          let _released =
                            Life.release_refreshed (Life.settled retry)
                          in
                          (remove state issue, effects)
                      | Scheduling_policy.Active ->
                          if routable state (Life.issue (Life.Refreshing retry))
                          then resume state issue retry now effects
                          else
                            let _released =
                              Life.release_refreshed (Life.settled retry)
                            in
                            (remove state issue, effects))
                | None
                | Some (Life.Starting _)
                | Some (Life.Active _)
                | Some (Life.Stopping _)
                | Some (Life.Waiting _)
                | Some (Life.Parked _)
                | Some (Life.Cleaning _) -> (state, effects))))
    | None
    | Some (Life.Starting _)
    | Some (Life.Active _)
    | Some (Life.Stopping _)
    | Some (Life.Waiting _)
    | Some (Life.Refreshing _)
    | Some (Life.Parked _)
    | Some (Life.Cleaning _) -> (state, effects)

  let completion (state : state) current completed now elapsed effects =
    let issue = Issue.id current in
    let outcome = Agent.outcome completed in
    let effects =
      match outcome with
      | Agent_runner.Succeeded -> effects
      | Agent_runner.Failed failure ->
          Report (Attempt_failure (current, failure)) :: effects
      | Agent_runner.Timed_out timeout ->
          Report (Attempt_timeout (current, timeout)) :: effects
      | Agent_runner.Stalled -> Report (Attempt_stalled current) :: effects
      | Agent_runner.Canceled { remote_error = Some diagnostic; _ } ->
          Report (Attempt_cancel_error (current, diagnostic)) :: effects
      | Agent_runner.Canceled { remote_error = None; _ } -> effects
    in
    fun finished ->
      let usage =
        match observation state issue with
        | None -> Usage.zero
        | Some value -> (Observation.view value).Observation.usage
      in
      let state =
        {
          state with
          ended = Seconds.add state.ended elapsed;
          ended_usage = Usage.add state.ended_usage usage;
        }
      in
      match finished with
      | Life.Releasable finished ->
          let _released = Life.release_run finished in
          (remove state issue, effects)
      | Life.Cleanable finished ->
          let state, request_id = fresh_request state in
          reserve_cleanup state (Life.clean_run finished ~request_id) effects
      | Life.Retryable finished ->
          let state, retry_id = fresh_retry state in
          let due =
            match Life.finish_cause finished with
            | Life.Continuation -> Clock.after now Backoff.continuation
            | Life.Attempt_failed _
            | Life.Attempt_timed_out _
            | Life.Stall
            | Life.Planning_failed _
            | Life.Refresh_failed _
            | Life.No_slots ->
                failure_due state now (Life.next_attempt finished)
          in
          let retry = Life.retry finished ~retry_id ~due in
          ( put state (Life.Waiting retry),
            Arm_retry (issue, retry_id, due) :: effects )

  (* Both closure orders retain the obligation under the new retry receipt. *)
  let retarget_deferred state issue run =
    let retarget value =
      match value.target with
      | Worker_target (id, token)
        when Issue_id.equal issue id && Run_id.equal run token -> (
          match find_owner issue state.owned with
          | Some (Life.Waiting retry) ->
              Some
                {
                  value with
                  target = Retry_target (issue, Life.retry_id retry);
                }
          | None
          | Some
              ( Life.Starting _
              | Life.Active _
              | Life.Stopping _
              | Life.Refreshing _
              | Life.Parked _
              | Life.Cleaning _ ) -> None)
      | Worker_target _ | Retry_target _ -> Some value
    in
    let jobs =
      Request_id.Map.map
        (fun job ->
          let deferred = Option.bind job.deferred retarget in
          let purpose =
            match job.purpose with
            | Deferred_reconcile value -> (
                match retarget value with
                | Some value -> Deferred_reconcile value
                | None -> job.purpose)
            | Startup_read
            | Reconcile _
            | Preflight _
            | Candidates _
            | Retry_read _
            | Continuation_read _
            | Remove _
            | Reload -> job.purpose
          in
          { job with deferred; purpose })
        state.jobs
    in
    { state with jobs }

  let worker_finished (state : state) completed now effects =
    let issue = Agent.completed_issue completed in
    let run_id = Agent.completed_run completed in
    match find_owner issue state.owned with
    | None -> (state, effects)
    | Some owner -> (
        match worker_run owner with
        | None -> (state, effects)
        | Some current when not (Run_id.equal current run_id) -> (state, effects)
        | Some _ -> (
            let state, effects =
              cancel_jobs state
                (function
                  | Continuation_read (id, token, _) ->
                      Issue_id.equal issue id && Run_id.equal run_id token
                  | Startup_read
                  | Reconcile _
                  | Preflight _
                  | Candidates _
                  | Retry_read _
                  | Deferred_reconcile _
                  | Remove _
                  | Reload -> false)
                effects
            in
            let current = Life.issue owner in
            let finish started result =
              match result with
              | Error diagnostic -> (state, report current diagnostic effects)
              | Ok finished ->
                  let state, effects =
                    completion state current completed now
                      (Clock.elapsed ~since:started ~until:now)
                      effects finished
                  in
                  (retarget_deferred state issue run_id, effects)
            in
            match owner with
            | Life.Starting run ->
                finish (Life.started run) (Life.finish_starting run completed)
            | Life.Active run ->
                finish (Life.started run) (Life.finish_active run completed)
            | Life.Stopping run ->
                finish (Life.started run) (Life.finish_stopping run completed)
            | Life.Waiting _
            | Life.Refreshing _
            | Life.Parked _
            | Life.Cleaning _ -> (state, effects)))

  let worker_started (state : state) issue token effects =
    match find_owner issue state.owned with
    | Some (Life.Starting run)
      when Run_id.equal token (Agent.run_id (Plan.request (Life.plan run))) ->
        (put state (Life.Active (Life.activate run)), effects)
    | None
    | Some (Life.Starting _)
    | Some (Life.Active _)
    | Some (Life.Stopping _)
    | Some (Life.Waiting _)
    | Some (Life.Refreshing _)
    | Some (Life.Parked _)
    | Some (Life.Cleaning _) -> (state, effects)

  let progress_fault owner error effects =
    let issue = Life.issue owner in
    let diagnostic =
      Diagnostic.make
        ~site:
          (Diagnostic.Issue
             { id = Issue.id issue; identifier = Issue.identifier issue })
        ~message:(Agent_observation.message error)
        ~remedy:"Correct the worker observation order and identity."
    in
    report issue diagnostic effects

  let worker_progress state issue run progress emitted_at now effects =
    match (find_owner issue state.owned, observation state issue) with
    | Some owner, Some current when worker_run owner = Some run -> (
        match Observation.observe current ~run ~now ~emitted_at progress with
        | Error error -> (state, progress_fault owner error effects)
        | Ok (_, Agent_observation.Ignored, _) -> (state, effects)
        | Ok (next, Agent_observation.Accepted, _) ->
            let state = put_observation state issue next in
            let latest_rate_limits =
              match Agent.notice progress with
              | Agent.Protocol (Agent_runner.Rate_limits limits) -> Some limits
              | Agent.Preparing
              | Agent.Workspace_ready _
              | Agent.Rendering
              | Agent.Starting
              | Agent.Protocol
                  ( Agent_runner.Session_started _
                  | Agent_runner.Turn_started _
                  | Agent_runner.Turn_completed _
                  | Agent_runner.Output _
                  | Agent_runner.Usage_report _
                  | Agent_runner.Unsupported_tool _ ) ->
                  state.latest_rate_limits
            in
            ({ state with latest_rate_limits }, effects))
    | None, _
    | ( Some
          ( Life.Starting _
          | Life.Active _
          | Life.Stopping _
          | Life.Waiting _
          | Life.Refreshing _
          | Life.Parked _
          | Life.Cleaning _ ),
        _ ) -> (state, effects)

  let worker_continue state issue run turn effects =
    match (find_owner issue state.owned, observation state issue) with
    | Some ((Life.Starting _ | Life.Active _) as owner), Some current
      when worker_run owner = Some run -> (
        match Observation.queue current ~turn with
        | Error error -> (state, progress_fault owner error effects)
        | Ok (_, Agent_observation.Ignored) -> (state, effects)
        | Ok (next, Agent_observation.Accepted) ->
            (put_observation state issue next, effects))
    | None, _
    | ( Some
          ( Life.Starting _
          | Life.Active _
          | Life.Stopping _
          | Life.Waiting _
          | Life.Refreshing _
          | Life.Parked _
          | Life.Cleaning _ ),
        _ ) -> (state, effects)

  (* Reserve the read after older issue reads close; a queued turn stays fenced. *)
  let begin_continuations state effects =
    if not (online state) then (state, effects)
    else
      List.fold_left
        (fun (state, effects) owner ->
          let issue = Issue.id (Life.issue owner) in
          let start run turn =
            let plan = Life.plan run in
            let run = Agent.run_id (Plan.request plan) in
            let state, id = fresh_request state in
            let state =
              add_job state id (Continuation_read (issue, run, turn))
            in
            let request =
              Tracker.Ids
                {
                  id;
                  binding = Plan.binding plan;
                  policy = read_policy state;
                  ids = Issue_id.Set.singleton issue;
                }
            in
            (state, Read_tracker request :: effects)
          in
          if has_job state (issue_read issue) then (state, effects)
          else
            match (owner, needs_continuation state issue) with
            | Life.Starting run, Some turn -> start run turn
            | Life.Active run, Some turn -> start run turn
            | ( ( Life.Starting _
                | Life.Active _
                | Life.Stopping _
                | Life.Waiting _
                | Life.Refreshing _
                | Life.Parked _
                | Life.Cleaning _ ),
                _ ) -> (state, effects))
        (state, effects) (owners state)

  let continuation_pending state =
    has_job state continuation_job
    || List.exists
         (fun owner ->
           match owner with
           | Life.Starting _ | Life.Active _ ->
               Option.is_some
                 (needs_continuation state (Issue.id (Life.issue owner)))
           | Life.Stopping _
           | Life.Waiting _
           | Life.Refreshing _
           | Life.Parked _
           | Life.Cleaning _ -> false)
         (owners state)

  let finish_continuation state issue run turn reply effects =
    match (find_owner issue state.owned, observation state issue) with
    | Some ((Life.Starting _ | Life.Active _) as owner), Some current
      when worker_run owner = Some run && Observation.need current = Some turn
      -> (
        match Observation.answer current ~turn with
        | Error error -> (state, progress_fault owner error effects)
        | Ok answered -> (
            let state = put_observation state issue answered in
            let respond state effects answer =
              (state, Continue_worker (issue, run, turn, answer) :: effects)
            in
            let stop state owner reason disposition effects =
              let state, effects =
                stop_owner state owner reason disposition
                  (Agent_runner.Cancel Agent_runner.Reconciliation) effects
              in
              respond state effects (Ok Agent_runner.Stop)
            in
            match reply with
            | Error error -> respond state effects (Error error)
            | Ok issues -> (
                match Issue_id.Map.find_opt issue issues with
                | None ->
                    stop state owner Stop_reason.Reconcile_missing Release
                      effects
                | Some refreshed -> (
                    let state, effects =
                      replace_current state owner refreshed effects
                    in
                    let owner =
                      Option.value (find_owner issue state.owned) ~default:owner
                    in
                    match
                      Scheduling_policy.classify (policy state)
                        (Life.issue owner)
                    with
                    | Scheduling_policy.Terminal ->
                        stop state owner Stop_reason.Reconcile_terminal Cleanup
                          effects
                    | Scheduling_policy.Inactive ->
                        stop state owner Stop_reason.Reconcile_inactive Release
                          effects
                    | Scheduling_policy.Active ->
                        if routable state (Life.issue owner) then
                          respond state effects
                            (Ok (Agent_runner.Continue (Life.issue owner)))
                        else
                          stop state owner Stop_reason.Reconcile_unroutable
                            Release effects))))
    | None, _
    | ( Some
          ( Life.Starting _
          | Life.Active _
          | Life.Stopping _
          | Life.Waiting _
          | Life.Refreshing _
          | Life.Parked _
          | Life.Cleaning _ ),
        _ ) -> (state, effects)

  let deferred_issue value =
    match value.target with
    | Worker_target (issue, _) | Retry_target (issue, _) -> issue

  let deferred_current state value =
    let issue = deferred_issue value in
    match (value.target, find_owner issue state.owned) with
    | Worker_target (_, run), Some (Life.Stopping stopped) ->
        worker_run (Life.Stopping stopped) = Some run
        && Life.after_close stopped = Life.Retry_after_close
    | Worker_target (_, run), Some owner -> worker_run owner = Some run
    | Retry_target (_, token), Some (Life.Waiting retry) ->
        Retry_id.equal token (Life.retry_id retry)
    | Worker_target _, None
    | ( Retry_target _,
        ( None
        | Some
            ( Life.Starting _
            | Life.Active _
            | Life.Stopping _
            | Life.Refreshing _
            | Life.Parked _
            | Life.Cleaning _ ) ) ) -> false

  let begin_deferred state value effects =
    if not (online state && deferred_current state value) then (state, effects)
    else
      let state, id = fresh_request state in
      let state = add_job state id (Deferred_reconcile value) in
      let request =
        Tracker.Ids
          {
            id;
            binding = value.original;
            policy = read_policy state;
            ids = Issue_id.Set.singleton (deferred_issue value);
          }
      in
      (state, Read_tracker request :: effects)

  (* A reconciliation may retire a closed retry, but cannot shorten its delay. *)
  let finish_deferred state value reply effects =
    let issue = deferred_issue value in
    if not (deferred_current state value) then (state, effects)
    else
      match reply with
      | Error error -> (state, Report (Tracker_failure error) :: effects)
      | Ok issues -> (
          match (value.target, find_owner issue state.owned) with
          | Worker_target (_, run), Some _ ->
              reconcile_one state (issue, run) issues effects
          | Retry_target (_, token), Some (Life.Waiting retry) -> (
              let retire state retry effects =
                let _released = Life.release_waiting retry in
                (remove state issue, Cancel_retry (issue, token) :: effects)
              in
              match Issue_id.Map.find_opt issue issues with
              | None -> retire state retry effects
              | Some current -> (
                  let state, effects =
                    replace_current state (Life.Waiting retry) current effects
                  in
                  match find_owner issue state.owned with
                  | Some (Life.Waiting retry) -> (
                      match
                        Scheduling_policy.classify (policy state) current
                      with
                      | Scheduling_policy.Terminal ->
                          terminal_retry state issue
                            (Life.settled (Life.refresh retry))
                            (Cancel_retry (issue, token) :: effects)
                      | Scheduling_policy.Inactive -> retire state retry effects
                      | Scheduling_policy.Active ->
                          if routable state current then (state, effects)
                          else retire state retry effects)
                  | None
                  | Some
                      ( Life.Starting _
                      | Life.Active _
                      | Life.Stopping _
                      | Life.Refreshing _
                      | Life.Parked _
                      | Life.Cleaning _ ) -> (state, effects)))
          | Worker_target _, None
          | ( Retry_target _,
              ( None
              | Some
                  ( Life.Starting _
                  | Life.Active _
                  | Life.Stopping _
                  | Life.Refreshing _
                  | Life.Parked _
                  | Life.Cleaning _ ) ) ) -> (state, effects))

  let close_job (state : state) id =
    let loading =
      match (state.loading, Request_id.Map.find_opt id state.jobs) with
      | Awaiting latest, Some { custody = Canceling; _ }
        when Request_id.equal latest id -> Settled
      | (Settled | Awaiting _), (None | Some { custody = Live | Canceling; _ })
        -> state.loading
    in
    { state with loading; jobs = Request_id.Map.remove id state.jobs }

  let tracker_completed (state : state) id reply now effects =
    match Request_id.Map.find_opt id state.jobs with
    | None -> (state, effects)
    | Some { purpose = Preflight _ | Reload | Remove _; _ } -> (state, effects)
    | Some
        ({
           purpose =
             ( Startup_read
             | Reconcile _
             | Candidates _
             | Retry_read _
             | Continuation_read _
             | Deferred_reconcile _ );
           _;
         } as job) -> (
        let state = close_job state id in
        let current =
          match job.custody with
          | Canceling -> false
          | Live -> equal_epoch job.epoch state.epoch
        in
        match job.purpose with
        | Continuation_read (issue, run, turn) -> (
            let state, effects =
              if current && online state then
                finish_continuation state issue run turn reply effects
              else (state, effects)
            in
            match job.deferred with
            | Some value -> begin_deferred state value effects
            | None -> wake_closed_continuation state issue now effects)
        | Deferred_reconcile value ->
            if current && online state then
              let state, effects = finish_deferred state value reply effects in
              wake_closed_continuation state (deferred_issue value) now effects
            else begin_deferred state value effects
        | Retry_read (issue, token) ->
            if current && online state then
              finish_retry state issue token reply now effects
            else discard_retry state issue token effects
        | Startup_read -> (
            match state.stage with
            | Boot (Reading epoch) when current && equal_epoch epoch job.epoch
              -> (
                let state = { state with stage = Boot (Removing epoch) } in
                match reply with
                | Error error ->
                    (state, Report (Tracker_failure error) :: effects)
                | Ok issues ->
                    List.fold_left
                      (fun (state, effects) (_, issue) ->
                        if
                          Scheduling_policy.classify (policy state) issue
                          = Scheduling_policy.Terminal
                        then startup_issue state issue effects
                        else (state, effects))
                      (state, effects)
                      (Issue_id.Map.bindings issues))
            | Boot (Reading _ | Removing _) | Online | Draining | Stopping_host
              -> (state, effects))
        | Reconcile (cycle_id, targets) -> (
            match (state.stage, state.cycle) with
            | Online, Reconciling authority
              when current && equal_epoch cycle_id authority.cycle_id -> (
                match reply with
                | Error error ->
                    (state, Report (Tracker_failure error) :: effects)
                | Ok issues ->
                    List.fold_left
                      (fun (state, effects) target ->
                        reconcile_one state target issues effects)
                      (state, effects) targets)
            | ( (Boot _ | Online | Draining | Stopping_host),
                (Idle | Reconciling _ | Validating _ | Fetching _ | Discarding)
              ) -> (state, effects))
        | Candidates cycle_id -> (
            match (state.stage, state.cycle) with
            | Online, Fetching authority
              when current && ready state
                   && equal_epoch cycle_id authority.cycle_id ->
                if continuation_pending state then
                  ({ state with cycle = Discarding }, effects)
                else
                  let state, effects =
                    match reply with
                    | Error error ->
                        (state, Report (Tracker_failure error) :: effects)
                    | Ok issues -> admit_candidates state issues now effects
                  in
                  finish_cycle state now effects
            | ( (Boot _ | Online | Draining | Stopping_host),
                (Idle | Reconciling _ | Validating _ | Fetching _ | Discarding)
              ) -> (state, effects))
        | Preflight _ | Remove _ | Reload -> (state, effects))

  let workspace_removed (state : state) id result effects =
    match Request_id.Map.find_opt id state.jobs with
    | Some { purpose = Remove issue; _ } -> (
        let state = close_job state id in
        match find_owner issue state.owned with
        | Some (Life.Cleaning cleanup)
          when Request_id.equal id
                 (Life.cleanup_request cleanup).Workspace.request_id ->
            let current = Life.issue (Life.Cleaning cleanup) in
            let _released = Life.cleaned cleanup in
            let effects =
              match result with
              | Ok () -> effects
              | Error error ->
                  Report (Cleanup_failure (current, error)) :: effects
            in
            (remove state issue, effects)
        | None
        | Some (Life.Starting _)
        | Some (Life.Active _)
        | Some (Life.Stopping _)
        | Some (Life.Waiting _)
        | Some (Life.Refreshing _)
        | Some (Life.Parked _)
        | Some (Life.Cleaning _) -> (state, effects))
    | None
    | Some
        {
          purpose =
            ( Startup_read
            | Reconcile _
            | Preflight _
            | Candidates _
            | Retry_read _
            | Continuation_read _
            | Deferred_reconcile _
            | Reload );
          _;
        } -> (state, effects)

  let request_canceled (state : state) id now effects =
    match Request_id.Map.find_opt id state.jobs with
    | None | Some { custody = Live; _ } -> (state, effects)
    | Some ({ custody = Canceling; _ } as job) -> (
        let state = close_job state id in
        let state =
          match state.loading with
          | Awaiting latest when Request_id.equal latest id ->
              { state with loading = Settled }
          | Settled | Awaiting _ -> state
        in
        match job.purpose with
        | Retry_read (issue, token) -> discard_retry state issue token effects
        | Continuation_read (issue, _, _) -> (
            match job.deferred with
            | Some value -> begin_deferred state value effects
            | None -> wake_closed_continuation state issue now effects)
        | Deferred_reconcile value -> begin_deferred state value effects
        | Startup_read
        | Reconcile _
        | Preflight _
        | Candidates _
        | Remove _
        | Reload -> (state, effects))

  let workflow_loaded (state : state) id result now effects =
    match Request_id.Map.find_opt id state.jobs with
    | None -> (state, effects)
    | Some job when not (load_job job.purpose) -> (state, effects)
    | Some job -> (
        let state = close_job state id in
        let selected =
          match (job.custody, state.loading) with
          | Live, Awaiting latest -> Request_id.equal latest id
          | (Live | Canceling), (Settled | Awaiting _) -> false
        in
        if not selected then (state, effects)
        else
          let old = effective state in
          let config = Config.apply state.config result in
          let state = { state with config; loading = Settled } in
          match result with
          | Error error -> (state, Report (Config_failure error) :: effects)
          | Ok accepted -> (
              let changed = not (Config.equal old accepted) in
              let scope_changed =
                not
                  (Tracker_scope.equal
                     (Tracker.scope (Config.tracker old))
                     (Tracker.scope (Config.tracker accepted)))
              in
              let state =
                if changed then
                  { state with epoch = Count.add state.epoch Count.one }
                else state
              in
              match state.stage with
              | Stopping_host -> (state, effects)
              | Draining -> (state, effects)
              | (Boot _ | Online) when scope_changed ->
                  drain state Draining Stop_reason.Scope_changed
                    (Agent_runner.Cancel Agent_runner.Scope_change) effects
              | Boot _ | Online -> (
                  let state, effects =
                    if changed then cancel_jobs state policy_job effects
                    else (state, effects)
                  in
                  let cycle =
                    match (state.cycle, job.purpose) with
                    | Validating authority, Preflight cycle
                      when equal_epoch cycle authority.cycle_id ->
                        Validating { authority with epoch = state.epoch }
                    | ( Idle,
                        ( Startup_read
                        | Reconcile _
                        | Preflight _
                        | Candidates _
                        | Retry_read _
                        | Continuation_read _
                        | Deferred_reconcile _
                        | Remove _
                        | Reload ) ) -> Idle
                    | ( (Reconciling _ | Validating _ | Fetching _ | Discarding),
                        ( Startup_read
                        | Reconcile _
                        | Preflight _
                        | Candidates _
                        | Retry_read _
                        | Continuation_read _
                        | Deferred_reconcile _
                        | Remove _
                        | Reload ) ) ->
                        if changed then Discarding else state.cycle
                  in
                  let state = { state with cycle } in
                  let state, effects = wake_retries state now effects in
                  match (state.stage, state.cycle, job.purpose) with
                  | Online, Idle, Reload -> arm_poll state now effects
                  | ( (Boot _ | Online | Draining | Stopping_host),
                      ( Idle
                      | Reconciling _
                      | Validating _
                      | Fetching _
                      | Discarding ),
                      ( Startup_read
                      | Reconcile _
                      | Preflight _
                      | Candidates _
                      | Retry_read _
                      | Continuation_read _
                      | Deferred_reconcile _
                      | Remove _
                      | Reload ) ) -> (state, effects))))

  (* Barriers inspect the canonical ledger; no second pending-ID set exists. *)
  let rec advance (state : state) now effects =
    let state, effects = begin_continuations state effects in
    match state.stage with
    | Stopping_host -> (state, effects)
    | Draining ->
        if Request_id.Map.is_empty state.jobs && unowned state && settled state
        then begin_startup state effects
        else (state, effects)
    | Boot (Reading _) ->
        if Request_id.Map.is_empty state.jobs && settled state then
          begin_startup state effects
        else (state, effects)
    | Boot (Removing epoch) ->
        if
          (not (Request_id.Map.is_empty state.jobs))
          || (not (unowned state))
          || not (settled state)
        then (state, effects)
        else if not (equal_epoch epoch state.epoch) then
          begin_startup state effects
        else arm_poll { state with stage = Online } now effects
    | Online -> (
        match state.cycle with
        | Idle -> (state, effects)
        | Discarding ->
            if
              has_job state cycle_job || continuation_pending state
              || not (settled state)
            then (state, effects)
            else if ready state then
              let state, effects = begin_cycle state effects in
              advance state now effects
            else finish_cycle state now effects
        | Reconciling authority ->
            if
              has_job state (for_cycle authority.cycle_id)
              || continuation_pending state
            then (state, effects)
            else begin_preflight state authority effects
        | Validating authority ->
            if
              has_job state (for_cycle authority.cycle_id)
              || continuation_pending state
              || not (settled state)
            then (state, effects)
            else if ready state && equal_epoch authority.epoch state.epoch then
              begin_candidates state authority effects
            else finish_cycle state now effects
        | Fetching _ -> (state, effects))

  let workflow_changed (state : state) effects =
    match state.stage with
    | Stopping_host -> (state, effects)
    | Boot _ | Draining | Online ->
        let cycle, purpose =
          match state.cycle with
          | Idle | Reconciling _ -> (state.cycle, Reload)
          | Validating authority -> (state.cycle, Preflight authority.cycle_id)
          | Fetching _ | Discarding -> (Discarding, Reload)
        in
        (* Watcher invalidation is independent of the replacement load's purpose. *)
        let state, effects = cancel_jobs state load_invalidates effects in
        begin_load { state with cycle } purpose effects

  let retry_due (state : state) issue token now effects =
    match (state.stage, find_owner issue state.owned) with
    | Online, Some (Life.Waiting retry)
      when ready state
           && Retry_id.equal token (Life.retry_id retry)
           && Clock.compare now (Life.due retry) >= 0 ->
        refresh_waiting state issue retry effects
    | ( (Boot _ | Online | Draining | Stopping_host),
        ( None
        | Some (Life.Starting _)
        | Some (Life.Active _)
        | Some (Life.Stopping _)
        | Some (Life.Waiting _)
        | Some (Life.Refreshing _)
        | Some (Life.Parked _)
        | Some (Life.Cleaning _) ) ) -> (state, effects)

  let begin_refresh (state : state) effects =
    match (state.stage, state.cycle) with
    | Online, Idle -> begin_cycle state effects
    | ( (Boot _ | Online | Draining | Stopping_host),
        (Idle | Reconciling _ | Validating _ | Fetching _ | Discarding) ) ->
        (state, effects)

  let check_stalls state now effects =
    match Scheduling_policy.stall (policy state) with
    | Scheduling_policy.Disabled -> (state, effects)
    | Scheduling_policy.Silence_limit limit ->
        List.fold_left
          (fun (state, effects) owner ->
            let check run =
              let activity =
                Option.bind
                  (observation state (Issue.id (Life.issue owner)))
                  (fun value ->
                    (Observation.view value).Observation.last_activity)
              in
              let since = Option.value activity ~default:(Life.started run) in
              if Clock.compare now (Clock.after since limit) <= 0 then
                (state, effects)
              else
                stop_owner state owner Stop_reason.Stall_detected
                  Retry_after_stop Agent_runner.Stall effects
            in
            match owner with
            | Life.Starting run -> check run
            | Life.Active run -> check run
            | Life.Stopping _
            | Life.Waiting _
            | Life.Refreshing _
            | Life.Parked _
            | Life.Cleaning _ -> (state, effects))
          (state, effects) (owners state)

  let refresh_requested (state : state) now effects =
    if not (online state) then (state, effects)
    else
      let state, effects = check_stalls state now effects in
      begin_refresh state effects

  let poll_due (state : state) token now effects =
    match state.poll with
    | Some poll
      when Request_id.equal token poll.token && Clock.compare now poll.due >= 0
      ->
        let state, effects =
          check_stalls { state with poll = None } now effects
        in
        let state, effects =
          arm_poll state
            (Clock.after now (Scheduling_policy.poll_interval (policy state)))
            effects
        in
        begin_refresh state effects
    | None | Some _ -> (state, effects)

  let event ~now input = { now; input }

  let step (state : state) (event : event) =
    let state, effects =
      match event.input with
      | Poll_due token -> poll_due state token event.now []
      | Refresh_requested -> refresh_requested state event.now []
      | Workflow_changed -> workflow_changed state []
      | Workflow_loaded (id, result) ->
          workflow_loaded state id result event.now []
      | Tracker_completed (id, reply) ->
          tracker_completed state id reply event.now []
      | Worker_started (issue, run) -> worker_started state issue run []
      | Worker_progress { issue; run; progress; emitted_at } ->
          worker_progress state issue run progress emitted_at event.now []
      | Worker_continue (issue, run, turn) ->
          worker_continue state issue run turn []
      | Worker_finished completed ->
          worker_finished state completed event.now []
      | Request_canceled id -> request_canceled state id event.now []
      | Retry_due (issue, token) -> retry_due state issue token event.now []
      | Workspace_removed (id, result) -> workspace_removed state id result []
      | Shutdown ->
          drain state Stopping_host Stop_reason.Shutdown_requested
            (Agent_runner.Cancel Agent_runner.Host_shutdown) []
    in
    let state, effects = advance state event.now effects in
    (state, List.rev effects)

  let create ~now:(_ : instant) config =
    let state =
      {
        config = Config.initial config;
        epoch = Count.zero;
        stage = Boot (Reading Count.zero);
        cycle = Idle;
        loading = Settled;
        owned = Owners.empty;
        jobs = Request_id.Map.empty;
        poll = None;
        requests = Request_id.Allocator.empty;
        runs = Run_id.Allocator.empty;
        retries = Retry_id.Allocator.empty;
        cycles = Count.zero;
        ended = Seconds.zero;
        ended_usage = Usage.zero;
        latest_rate_limits = None;
      }
    in
    let state, effects = begin_startup state [] in
    (state, List.rev effects)

  let project ~now (state : state) =
    let worker owner run phase =
      let observed =
        match observation state (Issue.id (Life.issue owner)) with
        | Some value -> Observation.view value
        | None -> assert false
      in
      Worker
        {
          issue = Life.issue owner;
          run = Agent.run_id (Plan.request (Life.plan run));
          phase;
          attempt = Agent.attempt (Plan.request (Life.plan run));
          seconds_running = Clock.elapsed ~since:(Life.started run) ~until:now;
          agent_phase = observed.Observation.phase;
          session = observed.Observation.session;
          turn_count = observed.Observation.turn_count;
          last_event = observed.Observation.last_event;
          last_message = observed.Observation.last_message;
          last_activity = observed.Observation.last_activity;
          usage = observed.Observation.usage;
          rate_limits = observed.Observation.rate_limits;
        }
    in
    let retry owner value phase =
      Retry
        {
          issue = Life.issue owner;
          retry = Life.retry_id value;
          phase;
          attempt = Life.attempt value;
        }
    in
    let rows =
      List.map
        (fun owner ->
          match owner with
          | Life.Starting run -> worker owner run Starting
          | Life.Active run -> worker owner run Active
          | Life.Stopping run -> worker owner run Stopping
          | Life.Waiting value -> retry owner value (Waiting (Life.due value))
          | Life.Refreshing value -> retry owner value Refreshing
          | Life.Parked value -> retry owner value Parked
          | Life.Cleaning _ -> Cleaning (Life.issue owner))
        (owners state)
    in
    let running = worker_count state in
    let mode =
      match state.stage with
      | Boot _ -> Startup
      | Online -> Serving
      | Draining -> Draining_scope
      | Stopping_host -> Shutting_down
    in
    let readiness =
      match state.loading with
      | Awaiting _ -> Loading
      | Settled -> (
          match Config.readiness state.config with
          | Config.Ready -> Ready
          | Config.Blocked _ -> Invalid)
    in
    let cycle : cycle_status =
      match state.cycle with
      | Idle -> Idle
      | Reconciling _ | Validating _ | Fetching _ | Discarding -> Busy
    in
    let total_runtime =
      List.fold_left
        (fun total -> function
          | Worker worker -> Seconds.add total worker.seconds_running
          | Retry _ | Cleaning _ -> total)
        state.ended rows
    in
    let total_usage =
      List.fold_left
        (fun total -> function
          | Worker worker -> Usage.add total worker.usage
          | Retry _ | Cleaning _ -> total)
        state.ended_usage rows
    in
    {
      mode;
      readiness;
      cycle;
      owners = rows;
      running;
      available_slots =
        max 0 (Scheduling_policy.global_limit (policy state) - running);
      total_runtime;
      total_usage;
      latest_rate_limits = state.latest_rate_limits;
    }

  let quiescent (state : state) =
    match state.stage with
    | Boot _ | Online | Draining -> false
    | Stopping_host -> Request_id.Map.is_empty state.jobs && unowned state
end
