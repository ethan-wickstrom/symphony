module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Clock : Clock.PURE)
    (Workspace : Workspace_manager.PURE)
    (Agent :
      Agent_runner.PURE
        with module Issue = Tracker.Issue
         and module Path = Workspace.Path
         and type workspace = Workspace.reference)
    (Plan :
      Run_plan.S
        with type binding = Tracker.binding
         and type request = Agent.request
         and type workspace = Workspace.reference) =
struct
  type unclaimed = Unclaimed of Issue.t
  type released = Released

  type disposition =
    | Retry_after_close
    | Release_after_close
    | Cleanup_after_close

  type run_data = { launch : Plan.t; current : Issue.t; start : Clock.instant }
  type stop = { reason : Stop_reason.t; disposition : disposition }
  type starting = Starting_state of run_data
  type active = Active_state of run_data
  type stopping = Stopping_state of run_data * stop

  type _ run =
    | Starting_run : starting -> starting run
    | Active_run : active -> active run
    | Stopping_run : stopping -> stopping run

  type retry_cause =
    | Continuation
    | Attempt_failed of Agent_runner.failure
    | Attempt_timed_out of Agent_runner.timeout
    | Stall
    | Planning_failed of Workspace_manager.error
    | Refresh_failed of Tracker_error.t
    | No_slots

  type retry_data = {
    snapshot : Issue.t;
    target : Plan.target;
    token : Retry_id.t;
    attempt : Positive_count.t;
    cause : retry_cause;
  }

  type waiting = Waiting_state of retry_data * Clock.instant
  type refreshing = Refreshing_state of retry_data
  type refreshed = Refreshed_state of retry_data
  type parked = Parked_state of retry_data

  (* Concrete carriers make phases distinct without unused phantom tags. A due
     time belongs to a waiting timer, never a read or parked reservation. *)
  type _ retry =
    | Waiting_retry : waiting -> waiting retry
    | Refreshing_retry : refreshing -> refreshing retry
    | Refreshed_retry : refreshed -> refreshed retry
    | Parked_retry : parked -> parked retry

  type cleanup = { cleanup_issue : Issue.t; request : Workspace.cleanup }
  type closed_data = { worker : run_data; closed : Agent.completed }

  (* Classify closed live outcomes once behind this module's boundary. A stall
     stop overrides the retry cause while retaining the original report; OCaml
     cannot refine the outcome inside the port's opaque completion witness. *)
  type worker_retry =
    | Clean_exit
    | Failed_exit of Agent_runner.failure
    | Deadline_exit of Agent_runner.timeout
    | Stalled_exit

  type retryable = Retry_state of closed_data * worker_retry
  type releasable = Release_state of closed_data
  type cleanable = Cleanup_state of closed_data

  type _ finished =
    | Retry_finished : retryable -> retryable finished
    | Release_finished : releasable -> releasable finished
    | Cleanup_finished : cleanable -> cleanable finished

  type completion =
    | Retryable of retryable finished
    | Releasable of releasable finished
    | Cleanable of cleanable finished

  type owned =
    | Starting of starting run
    | Active of active run
    | Stopping of stopping run
    | Waiting of waiting retry
    | Refreshing of refreshing retry
    | Parked of parked retry
    | Cleaning of cleanup

  type refresh_failure = Tracker_failed of Tracker_error.t | Slots_unavailable
  type terminal_retry = Release of released | Cleanup of cleanup

  let ( let* ) = Result.bind

  let diagnostic source message remedy =
    Diagnostic.make
      ~site:
        (Diagnostic.Issue
           { id = Issue.id source; identifier = Issue.identifier source })
      ~message ~remedy

  let check_identity source candidate =
    if
      Issue_id.equal (Issue.id source) (Issue.id candidate)
      && Issue_identifier.equal (Issue.identifier source)
           (Issue.identifier candidate)
    then Ok ()
    else
      Error
        (diagnostic source "launch identity differs from the current issue"
           "Build the plan from this issue's current ID and identifier.")

  let check_first source = function
    | Template.First -> Ok ()
    | Template.Follow_up _ ->
        Error
          (diagnostic source "initial launch has a retry attempt"
             "Build the initial plan with First.")

  let check_follow_up data = function
    | Template.Follow_up attempt
      when Count.compare
             (Positive_count.count attempt)
             (Positive_count.count data.attempt)
           = 0 -> Ok ()
    | Template.First | Template.Follow_up _ ->
        Error
          (diagnostic data.snapshot "retry launch has a different attempt"
             "Build the plan with Follow_up and the queued attempt.")

  let target_scope = function
    | Plan.Unnamed scope -> scope
    | Plan.Named reference -> Workspace.scope reference

  let check_scope data scope =
    if Tracker_scope.equal (target_scope data.target) scope then Ok ()
    else
      Error
        (diagnostic data.snapshot "retry launch changed tracker scope"
           "Drain the original reservation before dispatching another scope.")

  let unclaimed issue = Unclaimed issue

  let start (Unclaimed current) launch ~now =
    let request = Plan.request launch in
    let* () = check_identity current (Agent.issue request) in
    let* () = check_first current (Agent.attempt request) in
    Ok (Starting_run (Starting_state { launch; current; start = now }))

  let resume (Refreshed_retry (Refreshed_state data) : refreshed retry) launch
      ~now =
    let request = Plan.request launch in
    let* () = check_identity data.snapshot (Agent.issue request) in
    let* () = check_follow_up data (Agent.attempt request) in
    let* () = check_scope data (Tracker.scope (Plan.binding launch)) in
    Ok
      (Starting_run
         (Starting_state { launch; current = data.snapshot; start = now }))

  let run_data : type phase. phase run -> run_data = function
    | Starting_run (Starting_state data) -> data
    | Active_run (Active_state data) -> data
    | Stopping_run (Stopping_state (data, _)) -> data

  let retry_data : type phase. phase retry -> retry_data = function
    | Waiting_retry (Waiting_state (data, _)) -> data
    | Refreshing_retry (Refreshing_state data) -> data
    | Refreshed_retry (Refreshed_state data) -> data
    | Parked_retry (Parked_state data) -> data

  let closed_data : type disposition. disposition finished -> closed_data =
    function
    | Retry_finished (Retry_state (data, _)) -> data
    | Release_finished (Release_state data) -> data
    | Cleanup_finished (Cleanup_state data) -> data

  let activate (Starting_run (Starting_state data) : starting run) =
    Active_run (Active_state data)

  let stop_disposition = function
    | Stop_reason.Reconcile_terminal -> Cleanup_after_close
    | Stop_reason.Stall_detected -> Retry_after_close
    | Stop_reason.Reconcile_inactive
    | Stop_reason.Reconcile_missing
    | Stop_reason.Reconcile_unroutable
    | Stop_reason.Scope_changed
    | Stop_reason.Shutdown_requested -> Release_after_close

  let stop_starting (Starting_run (Starting_state data) : starting run) reason =
    Stopping_run
      (Stopping_state (data, { reason; disposition = stop_disposition reason }))

  let stop_active (Active_run (Active_state data) : active run) reason =
    Stopping_run
      (Stopping_state (data, { reason; disposition = stop_disposition reason }))

  let clean_after_close
      (Stopping_run (Stopping_state (data, stop)) : stopping run) =
    Stopping_run
      (Stopping_state (data, { stop with disposition = Cleanup_after_close }))

  let release_after_close
      (Stopping_run (Stopping_state (data, stop)) : stopping run) =
    let disposition =
      match stop.disposition with
      | Retry_after_close | Release_after_close -> Release_after_close
      | Cleanup_after_close -> Cleanup_after_close
    in
    Stopping_run (Stopping_state (data, { stop with disposition }))

  let close_worker worker closed =
    let request = Plan.request worker.launch in
    if
      Issue_id.equal
        (Issue.id (Agent.issue request))
        (Agent.completed_issue closed)
      && Run_id.equal (Agent.run_id request) (Agent.completed_run closed)
    then Ok { worker; closed }
    else
      Error
        (diagnostic worker.current "worker completion has a different identity"
           "Deliver the closed completion to its original issue and run.")

  let finish_live worker completed =
    let* data = close_worker worker completed in
    match Agent.outcome completed with
    | Agent_runner.Succeeded ->
        Ok (Retryable (Retry_finished (Retry_state (data, Clean_exit))))
    | Agent_runner.Failed failure ->
        Ok
          (Retryable (Retry_finished (Retry_state (data, Failed_exit failure))))
    | Agent_runner.Timed_out timeout ->
        Ok
          (Retryable
             (Retry_finished (Retry_state (data, Deadline_exit timeout))))
    | Agent_runner.Stalled ->
        Ok (Retryable (Retry_finished (Retry_state (data, Stalled_exit))))
    | Agent_runner.Canceled _ ->
        Ok (Releasable (Release_finished (Release_state data)))

  let finish_starting (Starting_run (Starting_state worker) : starting run)
      completed =
    finish_live worker completed

  let finish_active (Active_run (Active_state worker) : active run) completed =
    finish_live worker completed

  let finish_stopping
      (Stopping_run (Stopping_state (worker, stop)) : stopping run) completed =
    let* data = close_worker worker completed in
    match stop.disposition with
    | Retry_after_close ->
        Ok (Retryable (Retry_finished (Retry_state (data, Stalled_exit))))
    | Release_after_close ->
        Ok (Releasable (Release_finished (Release_state data)))
    | Cleanup_after_close ->
        Ok (Cleanable (Cleanup_finished (Cleanup_state data)))

  let failed_attempt request =
    match Agent.attempt request with
    | Template.First -> Positive_count.first
    | Template.Follow_up count -> Positive_count.next count

  let next_attempt
      (Retry_finished (Retry_state (data, reason)) : retryable finished) =
    match reason with
    | Clean_exit -> Positive_count.first
    | Failed_exit _ | Deadline_exit _ | Stalled_exit ->
        failed_attempt (Plan.request data.worker.launch)

  let finish_cause
      (Retry_finished (Retry_state (_, reason)) : retryable finished) =
    match reason with
    | Clean_exit -> Continuation
    | Failed_exit failure -> Attempt_failed failure
    | Deadline_exit timeout -> Attempt_timed_out timeout
    | Stalled_exit -> Stall

  let retry
      (Retry_finished (Retry_state (closed, _)) as finished :
        retryable finished) ~retry_id ~due =
    let data =
      {
        snapshot = closed.worker.current;
        target =
          Plan.Named (Agent.workspace (Plan.request closed.worker.launch));
        token = retry_id;
        attempt = next_attempt finished;
        cause = finish_cause finished;
      }
    in
    Waiting_retry (Waiting_state (data, due))

  let reject_start (Unclaimed source) rejection ~retry_id ~due =
    let* () = check_identity source (Plan.rejected_issue rejection) in
    let* () = check_first source (Plan.rejected_attempt rejection) in
    let data =
      {
        snapshot = source;
        target = Plan.rejected_target rejection;
        token = retry_id;
        attempt = Positive_count.first;
        cause = Planning_failed (Plan.rejected_error rejection);
      }
    in
    Ok (Waiting_retry (Waiting_state (data, due)))

  let reject_resume (Refreshed_retry (Refreshed_state data) : refreshed retry)
      rejection ~retry_id ~due =
    let* () = check_identity data.snapshot (Plan.rejected_issue rejection) in
    let* () = check_follow_up data (Plan.rejected_attempt rejection) in
    let* () =
      check_scope data (target_scope (Plan.rejected_target rejection))
    in
    Ok
      (Waiting_retry
         (Waiting_state
            ( {
                data with
                token = retry_id;
                attempt = Positive_count.next data.attempt;
                cause = Planning_failed (Plan.rejected_error rejection);
              },
              due )))

  let refresh (Waiting_retry (Waiting_state (data, _)) : waiting retry) =
    Refreshing_retry (Refreshing_state data)

  let settled (Refreshing_retry (Refreshing_state data) : refreshing retry) =
    Refreshed_retry (Refreshed_state data)

  let park (Refreshed_retry (Refreshed_state data) : refreshed retry) =
    Parked_retry (Parked_state data)

  let reread (Parked_retry (Parked_state data) : parked retry) =
    Refreshing_retry (Refreshing_state data)

  let requeue (Refreshed_retry (Refreshed_state data) : refreshed retry) failure
      ~retry_id ~due =
    let cause =
      match failure with
      | Tracker_failed error -> Refresh_failed error
      | Slots_unavailable -> No_slots
    in
    Waiting_retry
      (Waiting_state
         ( {
             data with
             token = retry_id;
             attempt = Positive_count.next data.attempt;
             cause;
           },
           due ))

  let release_waiting (Waiting_retry _ : waiting retry) = Released
  let release_refreshed (Refreshed_retry _ : refreshed retry) = Released
  let release_parked (Parked_retry _ : parked retry) = Released
  let release_run (Release_finished _ : releasable finished) = Released

  let clean_startup (Unclaimed source) (request : Workspace.cleanup) =
    let reference = request.Workspace.workspace in
    if
      Issue_id.equal (Issue.id source) (Workspace.issue_id reference)
      && Issue_identifier.equal (Issue.identifier source)
           (Workspace.identifier reference)
    then Ok { cleanup_issue = source; request }
    else
      Error
        (diagnostic source "startup cleanup has a different issue identity"
           "Build cleanup from the terminal issue's checked reference.")

  let cleanup worker request_id =
    let request : Workspace.cleanup =
      {
        Workspace.request_id;
        workspace = Agent.workspace (Plan.request worker.launch);
      }
    in
    { cleanup_issue = worker.current; request }

  let clean_run (Cleanup_finished (Cleanup_state data) : cleanable finished)
      ~request_id =
    cleanup data.worker request_id

  let terminal_retry (Refreshed_retry (Refreshed_state data) : refreshed retry)
      ~request_id =
    match data.target with
    | Plan.Unnamed _ -> Release Released
    | Plan.Named workspace ->
        let request : Workspace.cleanup = { Workspace.request_id; workspace } in
        Cleanup { cleanup_issue = data.snapshot; request }

  let cleaned (_ : cleanup) = Released
  let plan run = (run_data run).launch
  let started run = (run_data run).start

  let stop_reason (Stopping_run (Stopping_state (_, stop)) : stopping run) =
    stop.reason

  let after_close (Stopping_run (Stopping_state (_, stop)) : stopping run) =
    stop.disposition

  let finished_plan finished = (closed_data finished).worker.launch
  let finished_outcome finished = (closed_data finished).closed
  let retry_id retry = (retry_data retry).token
  let due (Waiting_retry (Waiting_state (_, due)) : waiting retry) = due
  let attempt retry = (retry_data retry).attempt
  let cause retry = (retry_data retry).cause
  let retry_target retry = (retry_data retry).target
  let cleanup_request cleanup = cleanup.request

  let issue = function
    | Starting run -> (run_data run).current
    | Active run -> (run_data run).current
    | Stopping run -> (run_data run).current
    | Waiting retry -> (retry_data retry).snapshot
    | Refreshing retry -> (retry_data retry).snapshot
    | Parked retry -> (retry_data retry).snapshot
    | Cleaning cleanup -> cleanup.cleanup_issue

  let replace_issue owner current =
    let source = issue owner in
    if not (Issue_id.equal (Issue.id source) (Issue.id current)) then
      Error
        (diagnostic source "issue refresh changed its opaque ID"
           "Route the refreshed issue to the reservation with its original ID.")
    else
      Ok
        (match owner with
        | Starting (Starting_run (Starting_state data)) ->
            Starting (Starting_run (Starting_state { data with current }))
        | Active (Active_run (Active_state data)) ->
            Active (Active_run (Active_state { data with current }))
        | Stopping (Stopping_run (Stopping_state (data, stop))) ->
            Stopping
              (Stopping_run (Stopping_state ({ data with current }, stop)))
        | Waiting (Waiting_retry (Waiting_state (data, due))) ->
            Waiting
              (Waiting_retry
                 (Waiting_state ({ data with snapshot = current }, due)))
        | Refreshing (Refreshing_retry (Refreshing_state data)) ->
            Refreshing
              (Refreshing_retry
                 (Refreshing_state { data with snapshot = current }))
        | Parked (Parked_retry (Parked_state data)) ->
            Parked
              (Parked_retry (Parked_state { data with snapshot = current }))
        | Cleaning cleanup -> Cleaning { cleanup with cleanup_issue = current })
end
