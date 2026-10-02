(** Independent fixture oracle: concrete lists, tagged integer counters and
    exact integer backoff. The signature states the corpus/event bounds; retries
    have no artificial attempt ceiling. No production module/planner calls. *)
type request = Request of int

type run = Run of int
type retry_id = Retry_id of int
type plan_mode = Accept | Decline
type key = Safe | Unsafe

type issue = {
  id : string;
  identifier : string;
  title : string;
  state : string;
  dispatchable : bool;
  labels : string list;
  priority : int option;
  created : int option;
  key : key;
}

type config = {
  binding : int;
  scope : int;
  root : int;
  launch : int;
  file : string;
  active : string list;
  terminal : string list;
  required : string list;
  global_cap : int;
  state_caps : (string * int) list;
  poll_ms : int;
  retry_cap_ms : int;
  plan_mode : plan_mode;
}
(** Binding/launch/root integers name finite fixture facts, never credentials.
    Safe+Accept succeeds; Unsafe rejects before a reference; Safe+Decline
    rejects after a reference but before effects. Startup ignores agent Decline.
*)

type reference = { scope : int; id : string; identifier : string; root : int }
type selection = States of string list | Ids of string list

type read = {
  id : request;
  binding : int;
  terminal : string list;
  selection : selection;
}

type start = {
  issue : issue;
  run : run;
  reference : reference;
  launch : int;
  attempt : int option;
}

type cancel_reason = Reconciliation | Scope_change | Host_shutdown

type outcome =
  | Succeeded
  | Failed
  | Timed_out
  | Stalled
  | Canceled
  | Cancel_error

type fault =
  | Config_failure
  | Tracker_failure
  | Issue_tracker_failure of issue
  | Planning_failure of issue
  | Cleanup_failure of issue
  | Lifecycle_failure of issue
  | Attempt_failure of issue
  | Attempt_timeout of issue
  | Attempt_stalled of issue
  | Attempt_cancel_error of issue

type command =
  | Load_workflow of request * string
  | Read_tracker of read
  | Start_worker of start
  | Stop_worker of string * run * cancel_reason
  | Remove_workspace of request * reference
  | Cancel_request of request
  | Arm_poll of request * int
  | Cancel_poll of request
  | Arm_retry of string * retry_id * int
  | Cancel_retry of string * retry_id
  | Report of fault

type input =
  | Poll_due of request
  | Refresh_requested
  | Workflow_changed
  | Workflow_loaded of request * (config, unit) result
  | Tracker_completed of request * (issue list, unit) result
  | Worker_started of string * run
  | Worker_finished of string * run * outcome
  | Request_canceled of request
  | Retry_due of string * retry_id
  | Workspace_removed of request * (unit, unit) result
  | Shutdown

type mode = Startup | Serving | Draining_scope | Shutting_down
type readiness = Ready | Loading | Invalid
type worker_phase = Starting | Active | Stopping
type retry_phase = Waiting of int | Refreshing | Parked

type worker = {
  issue : issue;
  run : run;
  phase : worker_phase;
  attempt : int option;
  seconds_ms : int;
}

type retry = {
  issue : issue;
  retry : retry_id;
  phase : retry_phase;
  attempt : int;
}

type owner = Worker of worker | Retry of retry | Cleaning of issue

type projection = {
  mode : mode;
  readiness : readiness;
  owners : owner list;
  running : int;
  available_slots : int;
  total_runtime_ms : int;
}

type disposition = Release | Cleanup
type status = Entering | Entered | Stopping_run of cancel_reason * disposition
type target = Unnamed of int | Named of reference

type cause =
  | Continuation
  | Attempt_error
  | Read_error
  | Slot_error
  | Plan_error

type retry_status = Timer of int | Reading | Dormant

type live = {
  current : issue;
  launch_request : start;
  binding_authority : int;
  status : status;
  started_ms : int;
}

type queued = {
  current : issue;
  target : target;
  token : retry_id;
  attempt_count : int;
  retry_status : retry_status;
}

type removal = { current : issue; request : request }
type owned = Live_run of live | Queued of queued | Removal of removal

type purpose =
  | Startup_read
  | Reconcile_read of int * (string * run) list
  | Preflight_load of int
  | Candidate_read of int
  | Retry_read of string * retry_id
  | Cleanup_job of string
  | Reload_load

type custody = Running_job | Canceling_job

type job = {
  token : request;
  epoch : int;
  purpose : purpose;
  custody : custody;
}

type control = Booting of int | Operating | Draining | Exiting

type cycle =
  | Idle
  | Reconciling of int
  | Checking of int
  | Fetching of int
  | Restarting

type validation = Valid | Rejected
type config_state = Known of validation | Awaiting of request * validation

type state = {
  config : config;
  epoch : int;
  validation : config_state;
  control : control;
  cycle : cycle;
  owners : owned list;
  jobs : job list;
  poll : (request * int) option;
  next_request : int;
  next_run : int;
  next_retry : int;
  next_cycle : int;
  ended_ms : int;
}

let continuation_ms = 1000
let base_backoff_ms = 10000
let normalize s = String.lowercase_ascii (String.trim s)
let names xs = List.sort_uniq String.compare (List.map normalize xs)
let same_request a b = a = b
let same_run a b = a = b
let same_retry a b = a = b

let readiness (state : state) =
  match state.validation with
  | Known Valid -> Ready
  | Known Rejected -> Invalid
  | Awaiting _ -> Loading

let owned_issue = function
  | Live_run live -> live.current
  | Queued retry -> retry.current
  | Removal removal -> removal.current

let owner_id (owner : owned) = (owned_issue owner).id

let find_owner id (state : state) =
  List.find_opt (fun owner -> owner_id owner = id) state.owners

let put owner (state : state) =
  let remaining =
    List.filter (fun old -> owner_id old <> owner_id owner) state.owners
  in
  {
    state with
    owners =
      List.sort
        (fun a b -> String.compare (owner_id a) (owner_id b))
        (owner :: remaining);
  }

let remove id (state : state) =
  {
    state with
    owners = List.filter (fun owner -> owner_id owner <> id) state.owners;
  }

let allocate_request (state : state) =
  ( Request state.next_request,
    { state with next_request = state.next_request + 1 } )

let allocate_run (state : state) =
  (Run state.next_run, { state with next_run = state.next_run + 1 })

let allocate_retry (state : state) =
  (Retry_id state.next_retry, { state with next_retry = state.next_retry + 1 })

let add_job token purpose (state : state) =
  let job = { token; epoch = state.epoch; purpose; custody = Running_job } in
  { state with jobs = state.jobs @ [ job ] }

let find_job token (state : state) =
  List.find_opt (fun (job : job) -> same_request token job.token) state.jobs

let drop_job token (state : state) =
  let validation =
    match state.validation with
    | Awaiting (selected, prior) when same_request token selected -> Known prior
    | Known _ | Awaiting _ -> state.validation
  in
  {
    state with
    validation;
    jobs =
      List.filter
        (fun (job : job) -> not (same_request token job.token))
        state.jobs;
  }

let combine (state, commands) f =
  let state, more = f state in
  (state, commands @ more)

let slots (state : state) =
  List.fold_left
    (fun total -> function
      | Live_run _ -> total + 1
      | Queued _ | Removal _ -> total)
    0 state.owners

let state_slots name (state : state) =
  List.fold_left
    (fun total -> function
      | Live_run live when normalize live.current.state = normalize name ->
          total + 1
      | Live_run _ | Queued _ | Removal _ -> total)
    0 state.owners

let state_cap (config : config) name =
  match
    List.find_opt
      (fun (state, _) -> normalize state = normalize name)
      config.state_caps
  with
  | Some (_, cap) -> cap
  | None -> config.global_cap

let routable (config : config) (issue : issue) =
  issue.dispatchable
  && List.for_all (fun label -> List.mem label issue.labels) config.required

let terminal (config : config) (issue : issue) =
  List.mem (normalize issue.state) (names config.terminal)

let active (config : config) (issue : issue) =
  List.mem (normalize issue.state) (names config.active)

let capacity (issue : issue) (state : state) =
  slots state < state.config.global_cap
  && state_slots issue.state state < state_cap state.config issue.state

let backoff (config : config) attempt =
  (* Exact closed form, capped before conversion to bounded fixture ticks. *)
  let absolute = Z.shift_left (Z.of_int base_backoff_ms) (attempt - 1) in
  Z.to_int (Z.min (Z.of_int config.retry_cap_ms) absolute)

let reference (config : config) (issue : issue) : reference =
  {
    scope = config.scope;
    id = issue.id;
    identifier = issue.identifier;
    root = config.root;
  }

let timer_cancel (state : state) =
  match state.poll with
  | None -> (state, [])
  | Some (token, _) -> ({ state with poll = None }, [ Cancel_poll token ])

let arm_poll due state =
  combine (timer_cancel state) (fun state ->
      let token, state = allocate_request state in
      ({ state with poll = Some (token, due) }, [ Arm_poll (token, due) ]))

let cancel_jobs predicate (state : state) =
  let jobs, commands =
    List.fold_left
      (fun (jobs, commands) (job : job) ->
        match job.custody with
        | Running_job when predicate job.purpose ->
            ( jobs @ [ { job with custody = Canceling_job } ],
              commands @ [ Cancel_request job.token ] )
        | Running_job | Canceling_job -> (jobs @ [ job ], commands))
      ([], []) state.jobs
  in
  ({ state with jobs }, commands)

let read purpose selection binding (state : state) =
  let id, state = allocate_request state in
  ( add_job id purpose state,
    [
      Read_tracker
        { id; binding; terminal = names state.config.terminal; selection };
    ] )

let load purpose (state : state) =
  let token, state = allocate_request state in
  let prior =
    match state.validation with
    | Known prior | Awaiting (_, prior) -> prior
  in
  ( add_job token purpose { state with validation = Awaiting (token, prior) },
    [ Load_workflow (token, state.config.file) ] )

let queue now (current : issue) target attempt_count cause (state : state) =
  let token, state = allocate_retry state in
  let delay =
    match cause with
    | Continuation -> continuation_ms
    | Attempt_error | Read_error | Slot_error | Plan_error ->
        backoff state.config attempt_count
  in
  let due = now + delay in
  let retry =
    { current; target; token; attempt_count; retry_status = Timer due }
  in
  (put (Queued retry) state, [ Arm_retry (current.id, token, due) ])

let remove_workspace (current : issue) reference (state : state) =
  let request, state = allocate_request state in
  let state = put (Removal { current; request }) state in
  ( add_job request (Cleanup_job current.id) state,
    [ Remove_workspace (request, reference) ] )

let plan now (current : issue) attempt old_target (state : state) =
  match (current.key, state.config.plan_mode) with
  | Unsafe, (Accept | Decline) ->
      let target =
        match old_target with
        | Some target -> target
        | None -> Unnamed state.config.scope
      in
      let count =
        match attempt with
        | None -> 1
        | Some count -> count + 1
      in
      combine
        (state, [ Report (Planning_failure current) ])
        (queue now current target count Plan_error)
  | Safe, Decline ->
      let target =
        match old_target with
        | Some target -> target
        | None -> Named (reference state.config current)
      in
      let count =
        match attempt with
        | None -> 1
        | Some count -> count + 1
      in
      combine
        (state, [ Report (Planning_failure current) ])
        (queue now current target count Plan_error)
  | Safe, Accept ->
      let run, state = allocate_run state in
      let request =
        {
          issue = current;
          run;
          reference = reference state.config current;
          launch = state.config.launch;
          attempt;
        }
      in
      let live =
        {
          current;
          launch_request = request;
          binding_authority = state.config.binding;
          status = Entering;
          started_ms = now;
        }
      in
      (put (Live_run live) state, [ Start_worker request ])

let groups (state : state) =
  List.fold_left
    (fun groups -> function
      | Queued _ | Removal _ -> groups
      | Live_run live ->
          let target = (live.current.id, live.launch_request.run) in
          let binding = live.binding_authority in
          if List.mem_assoc binding groups then
            List.map
              (fun (old, targets) ->
                if old = binding then (old, targets @ [ target ])
                else (old, targets))
              groups
          else groups @ [ (binding, [ target ]) ])
    [] state.owners

let finish_cycle now state =
  arm_poll (now + state.config.poll_ms) { state with cycle = Idle }

let cycle_pending cycle (state : state) =
  List.exists
    (fun (job : job) ->
      match job.purpose with
      | Reconcile_read (id, _) | Preflight_load id | Candidate_read id ->
          id = cycle
      | Startup_read | Retry_read _ | Cleanup_job _ | Reload_load -> false)
    state.jobs

let obsolete_cycle_job (state : state) =
  List.exists
    (fun (job : job) ->
      match job.purpose with
      | Reconcile_read _ | Preflight_load _ | Candidate_read _ -> true
      | Startup_read | Retry_read _ | Cleanup_job _ | Reload_load -> false)
    state.jobs

let borrow_validation cycle (state : state) =
  match state.validation with
  | Known _ -> state
  | Awaiting (selected, _) ->
      (* The selected load now fulfills this cycle's validation. Its cancellation
         still leaves that closure obligation in the canonical job ledger. *)
      {
        state with
        jobs =
          List.map
            (fun (job : job) ->
              if same_request selected job.token then
                { job with purpose = Preflight_load cycle }
              else job)
            state.jobs;
      }

let rec progress now (state : state) =
  match state.control with
  | Exiting -> (state, [])
  | Draining ->
      if state.owners = [] && state.jobs = [] then
        let state =
          { state with control = Booting state.epoch; cycle = Idle }
        in
        read Startup_read
          (States (names state.config.terminal))
          state.config.binding state
      else (state, [])
  | Booting epoch ->
      if state.jobs <> [] then (state, [])
      else if epoch <> state.epoch then
        read Startup_read
          (States (names state.config.terminal))
          state.config.binding
          { state with control = Booting state.epoch }
      else arm_poll now { state with control = Operating }
  | Operating -> (
      match state.cycle with
      | Idle -> (state, [])
      | Reconciling id ->
          if cycle_pending id state then (state, [])
          else if readiness state = Loading then
            (borrow_validation id { state with cycle = Checking id }, [])
          else load (Preflight_load id) { state with cycle = Checking id }
      | Checking id -> (
          if cycle_pending id state || readiness state = Loading then (state, [])
          else
            match readiness state with
            | Ready ->
                read (Candidate_read id)
                  (States (names state.config.active))
                  state.config.binding
                  { state with cycle = Fetching id }
            | Invalid -> finish_cycle now state
            | Loading -> (state, []))
      | Fetching id ->
          if cycle_pending id state then (state, []) else finish_cycle now state
      | Restarting -> (
          if obsolete_cycle_job state then (state, [])
          else
            match readiness state with
            | Loading -> (state, [])
            | Invalid -> finish_cycle now state
            | Ready -> begin_cycle now { state with cycle = Idle }))

and begin_cycle now state =
  let id = state.next_cycle in
  let state = { state with cycle = Reconciling id; next_cycle = id + 1 } in
  let state, commands =
    List.fold_left
      (fun acc (binding, targets) ->
        combine acc
          (read
             (Reconcile_read (id, targets))
             (Ids (List.map fst targets))
             binding))
      (state, []) (groups state)
  in
  combine (state, commands) (progress now)

let stop disposition reason (live : live) (state : state) =
  match live.status with
  | Entering | Entered ->
      let live = { live with status = Stopping_run (reason, disposition) } in
      ( put (Live_run live) state,
        [ Stop_worker (live.current.id, live.launch_request.run, reason) ] )
  | Stopping_run (first, old) ->
      let disposition =
        match (old, disposition) with
        | Cleanup, (Release | Cleanup) | Release, Cleanup -> Cleanup
        | Release, Release -> Release
      in
      ( put
          (Live_run { live with status = Stopping_run (first, disposition) })
          state,
        [] )

let reconcile targets (issues : issue list) (state : state) =
  List.fold_left
    (fun acc (id, run) ->
      combine acc (fun state ->
          match find_owner id state with
          | Some (Live_run live) when same_run live.launch_request.run run -> (
              match
                List.find_opt (fun (issue : issue) -> issue.id = id) issues
              with
              | None -> stop Release Reconciliation live state
              | Some current ->
                  let live = { live with current } in
                  let state = put (Live_run live) state in
                  if terminal state.config current then
                    stop Cleanup Reconciliation live state
                  else if
                    active state.config current && routable state.config current
                  then (state, [])
                  else stop Release Reconciliation live state)
          | Some (Live_run _ | Queued _ | Removal _) | None -> (state, [])))
    (state, []) targets

let compare_issue (a : issue) (b : issue) =
  let priority = function
    | Some p when p >= 1 && p <= 4 -> (0, p)
    | Some _ | None -> (1, 0)
  in
  let created = function
    | Some t -> (0, t)
    | None -> (1, 0)
  in
  Stdlib.compare
    (priority a.priority, created a.created, a.identifier)
    (priority b.priority, created b.created, b.identifier)

let admit now (issues : issue list) (state : state) =
  List.fold_left
    (fun acc (issue : issue) ->
      combine acc (fun state ->
          if
            state.control = Operating
            && readiness state = Ready
            && find_owner issue.id state = None
            && active state.config issue
            && (not (terminal state.config issue))
            && routable state.config issue
            && capacity issue state
          then plan now issue None None state
          else (state, [])))
    (state, [])
    (List.stable_sort compare_issue issues)

let begin_retry (retry : queued) (state : state) =
  let state = put (Queued { retry with retry_status = Reading }) state in
  read
    (Retry_read (retry.current.id, retry.token))
    (Ids [ retry.current.id ]) state.config.binding state

let awaken now (state : state) =
  if state.control <> Operating || readiness state <> Ready then (state, [])
  else
    List.fold_left
      (fun acc owner ->
        combine acc (fun state ->
            match owner with
            | Queued retry -> (
                match retry.retry_status with
                | Dormant -> begin_retry retry state
                | Timer due when now >= due ->
                    combine
                      (state, [ Cancel_retry (retry.current.id, retry.token) ])
                      (begin_retry retry)
                | Timer _ | Reading -> (state, []))
            | Live_run _ | Removal _ -> (state, [])))
      (state, []) state.owners

let closed_retry (job : job) (state : state) =
  match job.purpose with
  | Retry_read (id, token) -> (
      match find_owner id state with
      | Some (Queued retry) when same_retry retry.token token -> (
          match (retry.retry_status, state.control) with
          | Reading, (Exiting | Draining) -> (remove id state, [])
          | Reading, (Operating | Booting _) ->
              let retry = { retry with retry_status = Dormant } in
              let state = put (Queued retry) state in
              if state.control = Operating && readiness state = Ready then
                begin_retry retry state
              else (state, [])
          | (Timer _ | Dormant), (Booting _ | Operating | Draining | Exiting) ->
              (state, []))
      | Some (Live_run _ | Queued _ | Removal _) | None -> (state, []))
  | Startup_read
  | Reconcile_read _
  | Preflight_load _
  | Candidate_read _
  | Cleanup_job _
  | Reload_load -> (state, [])

let retry_result now id token result (state : state) =
  match find_owner id state with
  | Some (Queued retry) when same_retry retry.token token -> (
      match retry.retry_status with
      | Timer _ | Dormant -> (state, [])
      | Reading -> (
          match result with
          | Error () ->
              combine
                (state, [ Report (Issue_tracker_failure retry.current) ])
                (queue now retry.current retry.target (retry.attempt_count + 1)
                   Read_error)
          | Ok issues -> (
              let found =
                List.find_opt (fun (issue : issue) -> issue.id = id) issues
              in
              let retry =
                match found with
                | None -> retry
                | Some current -> { retry with current }
              in
              let state = put (Queued retry) state in
              if readiness state <> Ready then
                (put (Queued { retry with retry_status = Dormant }) state, [])
              else
                match found with
                | None -> (remove id state, [])
                | Some current ->
                    if terminal state.config current then
                      match retry.target with
                      | Unnamed _ -> (remove id state, [])
                      | Named reference ->
                          remove_workspace current reference state
                    else if
                      not
                        (active state.config current
                        && routable state.config current)
                    then (remove id state, [])
                    else if not (capacity current state) then
                      queue now current retry.target (retry.attempt_count + 1)
                        Slot_error state
                    else
                      plan now current (Some retry.attempt_count)
                        (Some retry.target) state)))
  | Some (Live_run _ | Queued _ | Removal _) | None -> (state, [])

let drain reason control (state : state) =
  let state, commands = timer_cancel { state with control; cycle = Idle } in
  let state, commands =
    List.fold_left
      (fun acc owner ->
        combine acc (fun state ->
            match owner with
            | Live_run live -> stop Release reason live state
            | Queued retry -> (
                match retry.retry_status with
                | Timer _ ->
                    ( remove retry.current.id state,
                      [ Cancel_retry (retry.current.id, retry.token) ] )
                | Dormant -> (remove retry.current.id state, [])
                | Reading -> (state, []))
            | Removal _ -> (state, [])))
      (state, commands) state.owners
  in
  combine (state, commands)
    (cancel_jobs (function
      | Cleanup_job _ -> false
      | Startup_read
      | Reconcile_read _
      | Preflight_load _
      | Candidate_read _
      | Retry_read _
      | Reload_load -> true))

let advance_epoch (state : state) =
  cancel_jobs
    (function
      | Cleanup_job _ -> false
      | Preflight_load _
      | Reload_load
      | Startup_read
      | Reconcile_read _
      | Candidate_read _
      | Retry_read _ -> true)
    state

let loaded now (job : job) result (state : state) =
  match result with
  | Error () ->
      combine
        ({ state with validation = Known Rejected }, [ Report Config_failure ])
        (progress now)
  | Ok config -> (
      let changed = config <> state.config in
      let scope_changed = config.scope <> state.config.scope in
      let state =
        {
          state with
          config;
          epoch = (state.epoch + if changed then 1 else 0);
          validation = Known Valid;
        }
      in
      if scope_changed && state.control <> Exiting then
        combine (drain Scope_change Draining state) (progress now)
      else
        let state, commands =
          if changed then advance_epoch state else (state, [])
        in
        let state =
          match (state.control, state.cycle, job.purpose) with
          | Operating, (Reconciling _ | Fetching _), Reload_load when changed ->
              { state with cycle = Restarting }
          | ( (Booting _ | Operating | Draining | Exiting),
              (Idle | Reconciling _ | Checking _ | Fetching _ | Restarting),
              ( Startup_read
              | Reconcile_read _
              | Preflight_load _
              | Candidate_read _
              | Retry_read _
              | Cleanup_job _
              | Reload_load ) ) -> state
        in
        let result = combine (state, commands) (awaken now) in
        let result = combine result (progress now) in
        match (job.purpose, state.control, state.cycle) with
        | Reload_load, Operating, Idle -> combine result (arm_poll now)
        | ( ( Startup_read
            | Reconcile_read _
            | Preflight_load _
            | Candidate_read _
            | Retry_read _
            | Cleanup_job _
            | Reload_load ),
            (Booting _ | Operating | Draining | Exiting),
            (Idle | Reconciling _ | Checking _ | Fetching _ | Restarting) ) ->
            result)

let workflow_changed (state : state) =
  match state.control with
  | Exiting -> (state, [])
  | Booting _ | Operating | Draining ->
      let result =
        cancel_jobs
          (function
            | Preflight_load _ | Candidate_read _ | Retry_read _ | Reload_load
              -> true
            | Startup_read | Reconcile_read _ | Cleanup_job _ -> false)
          state
      in
      let state, commands = result in
      let state =
        match state.cycle with
        | Fetching _ -> { state with cycle = Restarting }
        | Idle | Reconciling _ | Checking _ | Restarting -> state
      in
      let purpose =
        match state.cycle with
        | Checking cycle -> Preflight_load cycle
        | Idle | Reconciling _ | Fetching _ | Restarting -> Reload_load
      in
      combine (state, commands) (load purpose)

let finish_worker now id run outcome (state : state) =
  match find_owner id state with
  | Some (Live_run live) when same_run live.launch_request.run run ->
      let state =
        {
          (remove id state) with
          ended_ms = state.ended_ms + max 0 (now - live.started_ms);
        }
      in
      let failure_count =
        match live.launch_request.attempt with
        | None -> 1
        | Some n -> n + 1
      in
      let commands =
        match outcome with
        | Succeeded | Canceled -> []
        | Failed -> [ Report (Attempt_failure live.current) ]
        | Timed_out -> [ Report (Attempt_timeout live.current) ]
        | Stalled -> [ Report (Attempt_stalled live.current) ]
        | Cancel_error -> [ Report (Attempt_cancel_error live.current) ]
      in
      combine (state, commands) (fun state ->
          match live.status with
          | Stopping_run (_, Release) -> (state, [])
          | Stopping_run (_, Cleanup) ->
              remove_workspace live.current live.launch_request.reference state
          | Entering | Entered -> (
              match outcome with
              | Canceled | Cancel_error -> (state, [])
              | Succeeded ->
                  queue now live.current (Named live.launch_request.reference) 1
                    Continuation state
              | Failed | Timed_out | Stalled ->
                  queue now live.current (Named live.launch_request.reference)
                    failure_count Attempt_error state))
  | Some (Live_run _ | Queued _ | Removal _) | None -> (state, [])

let create ~now (config : config) =
  let state =
    {
      config;
      epoch = 0;
      validation = Known Valid;
      control = Booting 0;
      cycle = Idle;
      owners = [];
      jobs = [];
      poll = None;
      next_request = 0;
      next_run = 0;
      next_retry = 0;
      next_cycle = 0;
      ended_ms = 0;
    }
  in
  let _ = now in
  read Startup_read (States (names config.terminal)) config.binding state

let step ~now input (state : state) =
  let result =
    match input with
    | Shutdown -> (
        match state.control with
        | Exiting -> (state, [])
        | Booting _ | Operating | Draining -> drain Host_shutdown Exiting state)
    | Workflow_changed -> workflow_changed state
    | Refresh_requested -> (
        match (state.control, state.cycle) with
        | Operating, Idle -> combine (timer_cancel state) (begin_cycle now)
        | ( (Booting _ | Operating | Draining | Exiting),
            (Idle | Reconciling _ | Checking _ | Fetching _ | Restarting) ) ->
            (state, []))
    | Poll_due token -> (
        match (state.poll, state.control, state.cycle) with
        | Some (current, due), Operating, Idle
          when same_request current token && now >= due ->
            begin_cycle now { state with poll = None }
        | ( (None | Some _),
            (Booting _ | Operating | Draining | Exiting),
            (Idle | Reconciling _ | Checking _ | Fetching _ | Restarting) ) ->
            (state, []))
    | Retry_due (id, token) -> (
        match find_owner id state with
        | Some (Queued retry)
          when same_retry token retry.token
               && state.control = Operating
               && readiness state = Ready -> (
            match retry.retry_status with
            | Timer due when now >= due -> begin_retry retry state
            | Timer _ | Reading | Dormant -> (state, []))
        | Some (Live_run _ | Queued _ | Removal _) | None -> (state, []))
    | Worker_started (id, run) -> (
        match find_owner id state with
        | Some (Live_run live) when same_run run live.launch_request.run -> (
            match live.status with
            | Entering ->
                (put (Live_run { live with status = Entered }) state, [])
            | Entered | Stopping_run _ -> (state, []))
        | Some (Live_run _ | Queued _ | Removal _) | None -> (state, []))
    | Worker_finished (id, run, outcome) ->
        finish_worker now id run outcome state
    | Workflow_loaded (token, result) -> (
        match find_job token state with
        | Some job -> (
            match job.purpose with
            | Preflight_load _ | Reload_load -> (
                let state = drop_job token state in
                match job.custody with
                | Running_job -> loaded now job result state
                | Canceling_job -> (state, []))
            | Startup_read
            | Reconcile_read _
            | Candidate_read _
            | Retry_read _
            | Cleanup_job _ -> (state, []))
        | None -> (state, []))
    | Tracker_completed (token, result) -> (
        match find_job token state with
        | None -> (state, [])
        | Some job -> (
            match job.purpose with
            | Preflight_load _ | Reload_load | Cleanup_job _ -> (state, [])
            | Startup_read | Reconcile_read _ | Candidate_read _ | Retry_read _
              -> (
                let state = drop_job token state in
                if job.custody = Canceling_job || job.epoch <> state.epoch then
                  closed_retry job state
                else
                  match job.purpose with
                  | Startup_read -> (
                      match result with
                      | Error () -> (state, [ Report Tracker_failure ])
                      | Ok issues ->
                          List.fold_left
                            (fun acc (issue : issue) ->
                              combine acc (fun state ->
                                  if
                                    terminal state.config issue
                                    && find_owner issue.id state = None
                                  then
                                    match issue.key with
                                    | Unsafe ->
                                        ( state,
                                          [ Report (Planning_failure issue) ] )
                                    | Safe ->
                                        remove_workspace issue
                                          (reference state.config issue)
                                          state
                                  else (state, [])))
                            (state, [])
                            (List.sort
                               (fun (a : issue) (b : issue) ->
                                 String.compare a.id b.id)
                               issues))
                  | Reconcile_read (_, targets) -> (
                      match result with
                      | Error () -> (state, [ Report Tracker_failure ])
                      | Ok issues -> reconcile targets issues state)
                  | Candidate_read _ -> (
                      match result with
                      | Error () -> (state, [ Report Tracker_failure ])
                      | Ok issues ->
                          if
                            state.control = Operating && readiness state = Ready
                          then admit now issues state
                          else (state, []))
                  | Retry_read (id, retry) ->
                      retry_result now id retry result state
                  | Preflight_load _ | Cleanup_job _ | Reload_load -> (state, [])
                )))
    | Workspace_removed (token, result) -> (
        match find_job token state with
        | Some job -> (
            match job.purpose with
            | Cleanup_job id -> (
                match find_owner id state with
                | Some (Removal removal) when same_request removal.request token
                  -> (
                    let state = remove id (drop_job token state) in
                    ( state,
                      match result with
                      | Ok () -> []
                      | Error () -> [ Report (Cleanup_failure removal.current) ]
                    ))
                | Some (Live_run _ | Queued _ | Removal _) | None -> (state, [])
                )
            | Startup_read
            | Reconcile_read _
            | Preflight_load _
            | Candidate_read _
            | Retry_read _
            | Reload_load -> (state, []))
        | None -> (state, []))
    | Request_canceled token -> (
        match find_job token state with
        | Some job when job.custody = Canceling_job ->
            closed_retry job (drop_job token state)
        | Some _ | None -> (state, []))
  in
  combine result (progress now)

let project ~now (state : state) : projection =
  let owners =
    List.map
      (function
        | Live_run live ->
            let phase =
              match live.status with
              | Entering -> Starting
              | Entered -> Active
              | Stopping_run _ -> Stopping
            in
            Worker
              {
                issue = live.current;
                run = live.launch_request.run;
                phase;
                attempt = live.launch_request.attempt;
                seconds_ms = max 0 (now - live.started_ms);
              }
        | Queued retry ->
            let phase =
              match retry.retry_status with
              | Timer due -> Waiting due
              | Reading -> Refreshing
              | Dormant -> Parked
            in
            Retry
              {
                issue = retry.current;
                retry = retry.token;
                phase;
                attempt = retry.attempt_count;
              }
        | Removal removal -> Cleaning removal.current)
      state.owners
  in
  let running = slots state in
  let elapsed =
    List.fold_left
      (fun total -> function
        | Live_run live -> total + max 0 (now - live.started_ms)
        | Queued _ | Removal _ -> total)
      0 state.owners
  in
  let mode =
    match state.control with
    | Booting _ -> Startup
    | Operating -> Serving
    | Draining -> Draining_scope
    | Exiting -> Shutting_down
  in
  {
    mode;
    readiness = readiness state;
    owners;
    running;
    available_slots = max 0 (state.config.global_cap - running);
    total_runtime_ms = state.ended_ms + elapsed;
  }

let quiescent (state : state) =
  state.control = Exiting && state.owners = [] && state.jobs = []

let invariant (state : state) =
  let ids = List.map owner_id state.owners in
  let requests = List.map (fun (job : job) -> job.token) state.jobs in
  let unique values =
    List.length values = List.length (List.sort_uniq Stdlib.compare values)
  in
  let retry_jobs id token =
    List.filter
      (fun (job : job) ->
        match job.purpose with
        | Retry_read (other, retry) -> id = other && same_retry token retry
        | Startup_read
        | Reconcile_read _
        | Preflight_load _
        | Candidate_read _
        | Cleanup_job _
        | Reload_load -> false)
      state.jobs
  in
  let valid_owner = function
    | Live_run live -> (
        live.current.id = live.launch_request.issue.id
        && live.launch_request.reference.id = live.current.id
        &&
        match live.launch_request.attempt with
        | None -> true
        | Some attempt -> attempt > 0)
    | Queued retry -> (
        retry.attempt_count > 0
        &&
        match retry.retry_status with
        | Reading -> List.length (retry_jobs retry.current.id retry.token) = 1
        | Timer _ | Dormant -> retry_jobs retry.current.id retry.token = [])
    | Removal removal ->
        List.exists
          (fun (job : job) ->
            same_request job.token removal.request
            &&
            match job.purpose with
            | Cleanup_job id -> id = removal.current.id
            | Startup_read
            | Reconcile_read _
            | Preflight_load _
            | Candidate_read _
            | Retry_read _
            | Reload_load -> false)
          state.jobs
  in
  let loader (job : job) =
    match job.purpose with
    | Preflight_load _ | Reload_load -> true
    | Startup_read
    | Reconcile_read _
    | Candidate_read _
    | Retry_read _
    | Cleanup_job _ -> false
  in
  let valid_validation =
    match state.validation with
    | Known _ ->
        not
          (List.exists
             (fun (job : job) -> loader job && job.custody = Running_job)
             state.jobs)
    | Awaiting (selected, _) ->
        List.exists
          (fun (job : job) -> loader job && same_request job.token selected)
          state.jobs
        && List.for_all
             (fun (job : job) ->
               (not (loader job && job.custody = Running_job))
               || same_request job.token selected)
             state.jobs
  in
  if not (unique ids) then Error "duplicate owner ID"
  else if not (unique requests) then Error "duplicate live request generation"
  else if not valid_validation then
    Error "selected validation lost loader custody"
  else if not (List.for_all valid_owner state.owners) then
    Error "owner has invalid identity or custody"
  else Ok ()
