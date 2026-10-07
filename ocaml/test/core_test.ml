module F = Core_fixture
module C = F.Core
module T = Tracker_registry.Contract
open C
open F.Workspace

type harness = {
  state : C.state;
  now : int;
  commands : C.command list;
  history : C.command list;
}

let initial profile =
  let state, commands = C.create ~now:(F.instant 0) (F.config profile) in
  { state; now = 0; commands; history = commands }

let send ?now harness input =
  let now = Option.value ~default:harness.now now in
  let state, commands =
    C.step harness.state (C.event ~now:(F.instant now) input)
  in
  { state; now; commands; history = harness.history @ commands }

let projection harness = C.project ~now:(F.instant harness.now) harness.state

let choose message project commands =
  match List.find_map project commands with
  | Some value -> value
  | None -> Alcotest.fail message

let tracker = function
  | C.Read_tracker request -> Some request
  | C.Load_workflow _
  | C.Start_worker _
  | C.Stop_worker _
  | C.Continue_worker _
  | C.Remove_workspace _
  | C.Cancel_request _
  | C.Arm_poll _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let load = function
  | C.Load_workflow { id; _ } -> Some id
  | C.Read_tracker _
  | C.Start_worker _
  | C.Stop_worker _
  | C.Continue_worker _
  | C.Remove_workspace _
  | C.Cancel_request _
  | C.Arm_poll _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let poll = function
  | C.Arm_poll (id, due) -> Some (id, due)
  | C.Load_workflow _
  | C.Read_tracker _
  | C.Start_worker _
  | C.Stop_worker _
  | C.Continue_worker _
  | C.Remove_workspace _
  | C.Cancel_request _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let removal = function
  | C.Remove_workspace cleanup -> Some cleanup
  | C.Read_tracker _
  | C.Load_workflow _
  | C.Start_worker _
  | C.Stop_worker _
  | C.Continue_worker _
  | C.Cancel_request _
  | C.Arm_poll _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let worker = function
  | C.Start_worker request -> Some request
  | C.Read_tracker _
  | C.Load_workflow _
  | C.Remove_workspace _
  | C.Stop_worker _
  | C.Continue_worker _
  | C.Cancel_request _
  | C.Arm_poll _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let request_id = function
  | T.States { id; _ } | T.Ids { id; _ } -> id

let request_binding = function
  | T.States { binding; _ } | T.Ids { binding; _ } -> binding

let respond harness request reply =
  send harness (C.Tracker_completed (request_id request, reply))

let respond_first harness issues =
  respond harness
    (choose "Missing tracker command" tracker harness.commands)
    (F.reply issues)

let startup profile = respond_first (initial profile) []

let actual_reply issues = function
  | T.Ids { ids; _ } ->
      F.reply
        (List.filter
           (fun issue -> Issue_id.Set.mem (Issue.id issue) ids)
           issues)
  | T.States { names; _ } ->
      F.reply
        (List.filter
           (fun issue -> List.mem (Issue.state_key issue) names)
           issues)

(* This driver closes only fixture reads/loads; worker and cleanup closure stay
   explicit so an inner terminal cannot silently release an owner. *)
let close_reads ?config ~profile ~issues harness =
  let config = Option.value config ~default:(F.config profile) in
  let rec loop budget pending harness =
    match pending with
    | [] -> harness
    | _ when budget = 0 -> Alcotest.fail "Core read pipeline did not settle"
    | command :: rest -> (
        let next =
          match command with
          | C.Load_workflow { id; _ } ->
              Some (send harness (C.Workflow_loaded (id, Ok config)))
          | C.Read_tracker request ->
              Some (respond harness request (actual_reply issues request))
          | C.Start_worker _
          | C.Stop_worker _
          | C.Continue_worker _
          | C.Remove_workspace _
          | C.Cancel_request _
          | C.Arm_poll _
          | C.Cancel_poll _
          | C.Arm_retry _
          | C.Cancel_retry _
          | C.Report _ -> None
        in
        match next with
        | None -> loop (budget - 1) rest harness
        | Some next -> loop (budget - 1) (rest @ next.commands) next)
  in
  loop 64 harness.commands harness

let cycle ?config ?(profile = F.A) ~issues harness =
  close_reads ?config ~profile ~issues (send harness C.Refresh_requested)

let started_since harness = List.filter_map worker harness.history
let started_id request = Issue_id.text (Issue.id (F.Agent.issue request))
let owners harness = (projection harness).owners

let owner id harness =
  choose ("Missing owner " ^ id)
    (fun owner ->
      let issue =
        match owner with
        | C.Worker value -> value.issue
        | C.Retry value -> value.issue
        | C.Cleaning issue -> issue
      in
      if String.equal (Issue_id.text (Issue.id issue)) id then Some owner
      else None)
    (owners harness)

let run id harness =
  choose ("Missing launch " ^ id)
    (fun command ->
      match worker command with
      | Some request when String.equal (started_id request) id -> Some request
      | Some _ | None -> None)
    (List.rev harness.history)

let close_worker ?now harness request outcome =
  send ?now harness
    (C.Worker_finished
       (F.completed
          ~issue:(Issue.id (F.Agent.issue request))
          ~run:(F.Agent.run_id request) outcome))

let running expected harness =
  Alcotest.check Alcotest.int "Occupied slots" expected
    (projection harness).running

let no_command message project harness =
  Alcotest.check Alcotest.bool message true
    (List.for_all
       (fun command -> Option.is_none (project command))
       harness.commands)

let issue_a = F.issue ~id:"opaque-a" ~identifier:"CORE-1" ()
let issue_b = F.issue ~state:"Doing" ~id:"opaque-b" ~identifier:"CORE-2" ()

let startup_barrier () =
  let terminal = F.issue ~state:"Done" ~id:"old" ~identifier:"CORE-0" () in
  let pending = respond_first (initial F.A) [ terminal ] in
  let cleanup = choose "Startup cleanup missing" removal pending.commands in
  Alcotest.check Alcotest.bool "Startup mode" true
    ((projection pending).mode = C.Startup);
  let refreshed = send pending C.Refresh_requested in
  no_command "No admission before cleanup closure" worker refreshed;
  no_command "No workflow preflight before startup closure" load refreshed;
  Alcotest.check Alcotest.int "Cleanup retains claim" 1
    (List.length (owners refreshed));
  let closed =
    send refreshed
      (C.Workspace_removed
         ( cleanup.request_id,
           Error (Workspace_manager.Filesystem_error F.diagnostic) ))
  in
  Alcotest.check Alcotest.bool "Startup advances on closed error" true
    ((projection closed).mode = C.Serving);
  Alcotest.check Alcotest.int "Closed cleanup releases" 0
    (List.length (owners closed));
  let duplicate =
    send closed (C.Workspace_removed (cleanup.request_id, Ok ()))
  in
  Alcotest.check Alcotest.int "Duplicate close emits nothing" 0
    (List.length duplicate.commands)

let admission () =
  let unsafe = F.issue ~priority:1 ~id:"unsafe" ~identifier:"." () in
  let first = F.issue ~priority:2 ~id:"first" ~identifier:"CORE-3" () in
  let saturated = F.issue ~priority:3 ~id:"saturated" ~identifier:"CORE-4" () in
  let second =
    F.issue ~state:"Doing" ~priority:4 ~id:"second" ~identifier:"CORE-5" ()
  in
  let inactive =
    F.issue ~state:"Paused" ~id:"inactive" ~identifier:"CORE-6" ()
  in
  let routed =
    F.issue ~routing:Issue.Unroutable ~id:"unroutable" ~identifier:"CORE-7" ()
  in
  let result =
    cycle
      ~issues:[ second; saturated; unsafe; routed; inactive; first ]
      (startup F.A)
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "Named dispatch and state caps" [ "first"; "second" ]
    (List.map started_id (started_since result));
  running 2 result;
  (match owner "unsafe" result with
  | C.Retry retry ->
      Alcotest.check Alcotest.string "Pure rejection starts attempt one" "1"
        (Count.decimal (Positive_count.count retry.attempt))
  | C.Worker _ | C.Cleaning _ -> Alcotest.fail "Plan rejection owns a retry");
  let saturated = cycle ~issues:[ first; second; issue_a ] result in
  Alcotest.check Alcotest.int "Refresh cannot duplicate dispatch" 2
    (List.length (started_since saturated))

let retry_due () =
  let running_harness = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" running_harness in
  let active =
    send running_harness
      (C.Worker_started (Issue.id issue_a, F.Agent.run_id request))
  in
  let closed = close_worker ~now:12 active request Agent_runner.Succeeded in
  running 0 closed;
  let issue_id, token, due =
    choose "Success retry timer missing"
      (function
        | C.Arm_retry (id, token, due) -> Some (id, token, due)
        | C.Read_tracker _
        | C.Load_workflow _
        | C.Start_worker _
        | C.Stop_worker _
        | C.Continue_worker _
        | C.Remove_workspace _
        | C.Cancel_request _
        | C.Arm_poll _
        | C.Cancel_poll _
        | C.Cancel_retry _
        | C.Report _ -> None)
      closed.commands
  in
  Alcotest.check Alcotest.int "Continuation uses exact 1000ms" 0
    (Clock.Pure.compare due (F.instant 1012));
  let early = send ~now:1011 closed (C.Retry_due (issue_id, token)) in
  no_command "Early timer cannot read" tracker early;
  let due_harness = send ~now:1012 early (C.Retry_due (issue_id, token)) in
  let read = choose "Due retry must read by ID" tracker due_harness.commands in
  (match owner "opaque-a" due_harness with
  | C.Retry { phase = C.Refreshing; _ } -> ()
  | C.Retry { phase = C.Waiting _ | C.Parked; _ } | C.Worker _ | C.Cleaning _ ->
      Alcotest.fail "Retry lost refresh custody");
  let resumed = respond due_harness read (F.reply [ issue_a ]) in
  let follow_up = choose "Retry must resume" worker resumed.commands in
  Alcotest.check Alcotest.bool "Fresh run token" false
    (Run_id.equal (F.Agent.run_id request) (F.Agent.run_id follow_up));
  (match F.Agent.attempt follow_up with
  | Template.Follow_up n ->
      Alcotest.check Alcotest.string "Success resumes attempt one" "1"
        (Count.decimal (Positive_count.count n))
  | Template.First -> Alcotest.fail "Resumed worker has First attempt");
  let duplicate = close_worker resumed request Agent_runner.Succeeded in
  running 1 duplicate;
  Alcotest.check Alcotest.int "Old close cannot target resumed run" 0
    (List.length duplicate.commands);
  Alcotest.check Alcotest.string "Closure runtime counted once" "0.012"
    (Seconds.decimal (projection duplicate).total_runtime)

let grouped_reconciliation () =
  let first = cycle ~issues:[ issue_a ] (startup F.A) in
  let request_a = run "opaque-a" first in
  let loading = send first C.Workflow_changed in
  let q = choose "Reload command missing" load loading.commands in
  let reloaded = send loading (C.Workflow_loaded (q, Ok (F.config F.B))) in
  let two = cycle ~profile:F.B ~issues:[ issue_a; issue_b ] reloaded in
  let request_b = run "opaque-b" two in
  running 2 two;
  let reconciling = send two C.Refresh_requested in
  let reads = List.filter_map tracker reconciling.commands in
  Alcotest.check Alcotest.int "Original credentials form two groups" 2
    (List.length reads);
  let read profile =
    choose "Original-binding reconciliation group missing"
      (fun read ->
        if F.binding_profile (request_binding read) = profile then Some read
        else None)
      reads
  in
  let renamed =
    F.issue ~state:"Done" ~title:"Current terminal snapshot" ~id:"opaque-a"
      ~identifier:"RENAMED-1" ()
  in
  let half = respond reconciling (read F.A) (F.reply [ renamed ]) in
  no_command "Incomplete group barrier blocks preflight" load half;
  running 2 half;
  (match owner "opaque-a" half with
  | C.Worker { issue; phase = C.Stopping; _ } ->
      Alcotest.check Alcotest.string "Status uses refreshed issue" "RENAMED-1"
        (Issue_identifier.text (Issue.identifier issue))
  | C.Worker { phase = C.Starting | C.Active; _ } | C.Retry _ | C.Cleaning _ ->
      Alcotest.fail "Terminal run must stop");
  let settled = respond half (read F.B) (Error F.tracker_error) in
  ignore
    (choose "Closed group barrier advances preflight" load settled.commands);
  let closed = close_worker settled request_a Agent_runner.Succeeded in
  let cleanup =
    choose "Terminal worker cleanup missing" removal closed.commands
  in
  Alcotest.check Alcotest.string "Cleanup uses original identifier" "CORE-1"
    (Issue_identifier.text (F.Workspace.identifier cleanup.workspace));
  Alcotest.check Alcotest.string "Cleanup uses original root" "/fixture/root-a"
    (Absolute_path.display
       (Workspace_settings.root (F.Workspace.settings cleanup.workspace)));
  Alcotest.check Alcotest.bool "Other group's worker preserves token" true
    (match owner "opaque-b" closed with
    | C.Worker worker -> Run_id.equal worker.run (F.Agent.run_id request_b)
    | C.Retry _ | C.Cleaning _ -> false)

let parked_reload () =
  let h = cycle ~issues:[ issue_a ] (startup F.A) in
  let closed = close_worker h (run "opaque-a" h) Agent_runner.Succeeded in
  let id, retry =
    choose "Retry timer missing"
      (function
        | C.Arm_retry (id, retry, _) -> Some (id, retry)
        | C.Read_tracker _
        | C.Load_workflow _
        | C.Start_worker _
        | C.Stop_worker _
        | C.Continue_worker _
        | C.Remove_workspace _
        | C.Cancel_request _
        | C.Arm_poll _
        | C.Cancel_poll _
        | C.Cancel_retry _
        | C.Report _ -> None)
      closed.commands
  in
  let refreshing = send ~now:1000 closed (C.Retry_due (id, retry)) in
  let read = choose "Retry read missing" tracker refreshing.commands in
  let loading = send refreshing C.Workflow_changed in
  let latest = choose "Reload missing" load loading.commands in
  let blocked =
    send loading (C.Workflow_loaded (latest, Error F.invalid_config))
  in
  let parked = respond blocked read (F.reply [ issue_a ]) in
  (match owner "opaque-a" parked with
  | C.Retry { phase = C.Parked; retry = current; attempt; _ } ->
      Alcotest.check Alcotest.bool "Superseded read retains retry" true
        (Retry_id.equal retry current);
      Alcotest.check Alcotest.string "Policy replacement is not failure" "1"
        (Count.decimal (Positive_count.count attempt))
  | C.Retry { phase = C.Waiting _ | C.Refreshing; _ }
  | C.Worker _ | C.Cleaning _ -> Alcotest.fail "Expected parked owner");
  no_command "Invalid config emits no launch" worker parked;
  let repairing = send parked C.Workflow_changed in
  let load_id = choose "Repair reload missing" load repairing.commands in
  let ready =
    send repairing (C.Workflow_loaded (load_id, Ok (F.config F.New_policy)))
  in
  ignore (choose "Repair rereads parked retry" tracker ready.commands);
  let retry_owner = owner "opaque-a" ready in
  Alcotest.check Alcotest.bool "Repair preserves retry identity" true
    (match retry_owner with
    | C.Retry { phase = C.Refreshing; retry = current; _ } ->
        Retry_id.equal retry current
    | C.Retry { phase = C.Waiting _ | C.Parked; _ } | C.Worker _ | C.Cleaning _
      -> false)

let startup_reload_fence () =
  let h = initial F.A in
  let old = choose "Startup read missing" tracker h.commands in
  let loading = send h C.Workflow_changed in
  let q = choose "Startup reload missing" load loading.commands in
  let new_config = send loading (C.Workflow_loaded (q, Ok (F.config F.B))) in
  let terminal = F.issue ~state:"Done" ~id:"stale" ~identifier:"CORE-OLD" () in
  let stale = respond new_config old (F.reply [ terminal ]) in
  no_command "Obsolete payload cannot delete under a new root" removal stale;
  let fresh = choose "Superseded startup must reread" tracker stale.commands in
  Alcotest.check Alcotest.bool "Startup repeats with new authority" true
    (F.binding_profile (request_binding fresh) = F.B)

let shutdown_drain () =
  let h = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" h in
  let pending = send h C.Refresh_requested in
  let read = choose "Reconcile read missing" tracker pending.commands in
  let shutdown = send pending C.Shutdown in
  running 1 shutdown;
  Alcotest.check Alcotest.bool "Stop request cannot claim quiescence" false
    (C.quiescent shutdown.state);
  let duplicate = send shutdown C.Shutdown in
  Alcotest.check Alcotest.int "Shutdown idempotence" 0
    (List.length duplicate.commands);
  let worker_closed = close_worker duplicate request Agent_runner.Succeeded in
  running 0 worker_closed;
  Alcotest.check Alcotest.bool "Canceled read still holds custody" false
    (C.quiescent worker_closed.state);
  let drained = respond worker_closed read (F.reply [ issue_a ]) in
  Alcotest.check Alcotest.bool "Closed cancel/result race drains" true
    (C.quiescent drained.state);
  no_command "Shutdown absorbs produced result body" worker drained

let scope_drain () =
  let h = cycle ~issues:[ issue_a ] (startup F.A) in
  let old_request = run "opaque-a" h in
  let reading = send h C.Refresh_requested in
  let old_read = choose "Original reconcile missing" tracker reading.commands in
  let loading = send reading C.Workflow_changed in
  let q = choose "Scope reload missing" load loading.commands in
  let draining =
    send loading (C.Workflow_loaded (q, Ok (F.config F.Other_scope)))
  in
  Alcotest.check Alcotest.bool "Scope switch waits" true
    ((projection draining).mode = C.Draining_scope);
  no_command "New scope cannot read before old closure" tracker draining;
  running 1 draining;
  let worker_closed =
    close_worker draining old_request Agent_runner.Succeeded
  in
  no_command "Old read still blocks new startup" tracker worker_closed;
  let closed = respond worker_closed old_read (F.reply [ issue_a ]) in
  let new_read =
    choose "Drained scope starts fresh startup" tracker closed.commands
  in
  Alcotest.check Alcotest.bool "New startup uses latest scope" true
    (F.binding_profile (request_binding new_read) = F.Other_scope);
  let serving = respond closed new_read (F.reply []) in
  let reused = F.issue ~id:"opaque-a" ~identifier:"NEW-1" () in
  let relaunched = cycle ~profile:F.Other_scope ~issues:[ reused ] serving in
  running 1 relaunched;
  let new_request = run "opaque-a" relaunched in
  Alcotest.check Alcotest.bool "Scope reuse has fresh run identity" false
    (Run_id.equal (F.Agent.run_id old_request) (F.Agent.run_id new_request));
  let late = close_worker relaunched old_request Agent_runner.Succeeded in
  running 1 late;
  Alcotest.check Alcotest.int "Late old scope cannot release reused issue" 0
    (List.length late.commands)

let cleanup_absorbs_shutdown () =
  let h = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" h in
  let reading = send h C.Refresh_requested in
  let read = choose "Reconcile read missing" tracker reading.commands in
  let terminal =
    F.issue ~state:"Done" ~id:"opaque-a" ~identifier:"RENAMED" ()
  in
  let stopping = respond reading read (F.reply [ terminal ]) in
  let pending_load = choose "Preflight missing" load stopping.commands in
  let shutdown = send stopping C.Shutdown in
  let worker_closed = close_worker shutdown request Agent_runner.Succeeded in
  let cleanup =
    choose "Shutdown must preserve required cleanup" removal
      worker_closed.commands
  in
  Alcotest.check Alcotest.string "Required cleanup retains old identity"
    "CORE-1"
    (Issue_identifier.text (F.Workspace.identifier cleanup.workspace));
  Alcotest.check Alcotest.bool "Cleanup retains shutdown custody" false
    (C.quiescent worker_closed.state);
  let cleanup_closed =
    send worker_closed (C.Workspace_removed (cleanup.request_id, Ok ()))
  in
  let drained = send cleanup_closed (C.Request_canceled pending_load) in
  Alcotest.check Alcotest.bool "Shutdown finishes after cleanup and load close"
    true
    (C.quiescent drained.state)

type close_order = Old_first | Latest_first

let replace_preflight () =
  let check order harness =
    let reconciling = send harness C.Refresh_requested in
    let validating =
      match List.find_map tracker reconciling.commands with
      | None -> reconciling
      | Some read -> respond reconciling read (F.reply [ issue_a ])
    in
    let old = choose "Cycle preflight missing" load validating.commands in
    let changed = send validating C.Workflow_changed in
    let latest = choose "Replacement load missing" load changed.commands in
    Alcotest.check Alcotest.bool "Replacement gets fresh identity" false
      (Request_id.equal old latest);
    let old_closed = C.Workflow_loaded (old, Ok (F.config F.B)) in
    let latest_closed =
      C.Workflow_loaded (latest, Ok (F.config F.New_policy))
    in
    let first, last =
      match order with
      | Old_first -> (old_closed, latest_closed)
      | Latest_first -> (latest_closed, old_closed)
    in
    let closed = send changed first in
    no_command "One closed load cannot authorize candidates" tracker closed;
    let ready = send closed last in
    let read =
      choose "Latest validation must fulfill this cycle" tracker ready.commands
    in
    (match read with
    | T.States { names; policy; _ } ->
        Alcotest.check
          (Alcotest.list Alcotest.string)
          "Candidates use latest active states" [ "doing"; "todo" ] names;
        Alcotest.check
          (Alcotest.list Alcotest.string)
          "Candidates use latest terminal policy" [ "closed"; "done" ]
          (Tracker_read_policy.terminal policy)
    | T.Ids _ -> Alcotest.fail "Closed reconciliation must not repeat");
    no_command "Replacement cannot add a third preflight" load ready
  in
  List.iter
    (fun order ->
      check order (startup F.A);
      check order (cycle ~issues:[ issue_a ] (startup F.A)))
    [ Old_first; Latest_first ]

let canceled_load_readiness () =
  let check expected harness =
    let changed = send harness C.Workflow_changed in
    let selected = choose "Selected load missing" load changed.commands in
    let stopping = send changed C.Shutdown in
    Alcotest.check Alcotest.bool "Unclosed loader keeps loading" true
      ((projection stopping).readiness = C.Loading);
    let closed = send stopping (C.Request_canceled selected) in
    Alcotest.check Alcotest.bool "Closed loader restores prior validation" true
      ((projection closed).readiness = expected)
  in
  check C.Ready (startup F.A);
  let changed = send (startup F.A) C.Workflow_changed in
  let selected = choose "Invalid load missing" load changed.commands in
  let invalid =
    send changed (C.Workflow_loaded (selected, Error F.invalid_config))
  in
  check C.Invalid invalid

let invalid_candidate_reload () =
  let check order =
    let serving = startup F.A in
    let poll_id, _ = choose "Startup poll missing" poll serving.commands in
    let validating = send serving C.Refresh_requested in
    let preflight = choose "Preflight missing" load validating.commands in
    let fetching =
      send validating (C.Workflow_loaded (preflight, Ok (F.config F.A)))
    in
    let candidate = choose "Candidate read missing" tracker fetching.commands in
    let changed = send fetching C.Workflow_changed in
    let superseded = choose "Replacement load missing" load changed.commands in
    let changed_again = send changed C.Workflow_changed in
    let latest =
      choose "Latest replacement missing" load changed_again.commands
    in
    let first =
      match order with
      | Old_first -> respond changed_again candidate (F.reply [])
      | Latest_first ->
          send ~now:100 changed_again
            (C.Workflow_loaded (latest, Error F.invalid_config))
    in
    no_command "Half-closed invalid cycle cannot reload" load first;
    no_command "Half-closed invalid cycle cannot read" tracker first;
    let tick = send ~now:100 first (C.Poll_due poll_id) in
    no_command "Retained cadence cannot overlap invalid cycle reads" tracker
      tick;
    no_command "Retained cadence cannot overlap invalid cycle loads" load tick;
    let _, due = choose "Busy cycle retains cadence" poll tick.commands in
    let invalid =
      match order with
      | Old_first ->
          send ~now:100 tick
            (C.Workflow_loaded (latest, Error F.invalid_config))
      | Latest_first -> respond tick candidate (F.reply [])
    in
    no_command "Invalid config cannot immediately reload" load invalid;
    no_command "Invalid config cannot read candidates" tracker invalid;
    no_command "Cycle closure retains its existing cadence" poll invalid;
    Alcotest.check Alcotest.bool "Last-good poll interval sets due time" true
      (Clock.Pure.compare due (F.instant 105) = 0);
    let late =
      send invalid (C.Workflow_loaded (superseded, Ok (F.config F.B)))
    in
    Alcotest.check Alcotest.bool "Superseded result cannot repair readiness"
      true
      ((projection late).readiness = C.Invalid);
    no_command "Superseded result cannot restart validation" load late
  in
  List.iter check [ Old_first; Latest_first ]

let startup_loader_custody () =
  let check order =
    let terminal =
      F.issue ~state:"Done" ~id:"opaque-a" ~identifier:"CORE-1" ()
    in
    let removing = respond_first (initial F.A) [ terminal ] in
    let cleanup = choose "Startup cleanup missing" removal removing.commands in
    let changed = send removing C.Workflow_changed in
    let superseded =
      choose "First startup reload missing" load changed.commands
    in
    let changed_again = send changed C.Workflow_changed in
    let latest =
      choose "Selected startup reload missing" load changed_again.commands
    in
    let updated =
      send changed_again (C.Workflow_loaded (latest, Ok (F.config F.Tight)))
    in
    let changed_invalid = send updated C.Workflow_changed in
    let invalid_load =
      choose "Invalid startup reload missing" load changed_invalid.commands
    in
    let invalid =
      send changed_invalid
        (C.Workflow_loaded (invalid_load, Error F.invalid_config))
    in
    let removal_closed = C.Workspace_removed (cleanup.request_id, Ok ()) in
    let loader_closed = C.Request_canceled superseded in
    let first, last =
      match order with
      | Old_first -> (loader_closed, removal_closed)
      | Latest_first -> (removal_closed, loader_closed)
    in
    let half_closed = send invalid first in
    no_command "Bootstrap waits for every old resource" tracker half_closed;
    let drained = send half_closed last in
    let read =
      choose "Drained bootstrap rereads last-good epoch" tracker
        drained.commands
    in
    (match read with
    | T.States { names; _ } ->
        Alcotest.check
          (Alcotest.list Alcotest.string)
          "Startup repeats terminal cleanup" [ "done" ] names
    | T.Ids _ -> Alcotest.fail "Bootstrap must fetch terminal states");
    Alcotest.check Alcotest.int "Latest invalid load retains last-good cap" 1
      (projection drained).available_slots;
    Alcotest.check Alcotest.bool "Cleanup cannot repair invalid config" true
      ((projection drained).readiness = C.Invalid)
  in
  List.iter check [ Old_first; Latest_first ]

let startup_final_loader () =
  let starting = initial F.A in
  let startup_read = choose "Startup read missing" tracker starting.commands in
  let changed = send starting C.Workflow_changed in
  let selected = choose "Bootstrap reload missing" load changed.commands in
  let read_closed = respond changed startup_read (F.reply []) in
  Alcotest.check Alcotest.bool "Loader retains bootstrap" true
    ((projection read_closed).mode = C.Startup);
  let serving =
    send ~now:100 read_closed (C.Workflow_loaded (selected, Ok (F.config F.A)))
  in
  Alcotest.check Alcotest.bool "Final loader closes bootstrap" true
    ((projection serving).mode = C.Serving);
  Alcotest.check Alcotest.int "One initial timer without transient churn" 1
    (List.length serving.commands);
  let _, due =
    choose "Bootstrap must arm exactly one initial poll" poll serving.commands
  in
  Alcotest.check Alcotest.int "Initial poll is immediate" 0
    (Clock.Pure.compare due (F.instant 100))

let borrowed_preflight_custody () =
  let check order =
    let started = cycle ~issues:[ issue_a ] (startup F.A) in
    let poll_id, _ = choose "Startup poll missing" poll started.history in
    let reading = send started C.Refresh_requested in
    let reconcile = choose "Reconciliation missing" tracker reading.commands in
    let changed = send reading C.Workflow_changed in
    let borrowed = choose "Concurrent reload missing" load changed.commands in
    let validating = respond changed reconcile (F.reply [ issue_a ]) in
    no_command "Existing selected load fulfills preflight" load validating;
    let changed_again = send validating C.Workflow_changed in
    let latest =
      choose "Preflight replacement missing" load changed_again.commands
    in
    let first, last =
      match order with
      | Old_first ->
          ( C.Request_canceled borrowed,
            C.Workflow_loaded (latest, Error F.invalid_config) )
      | Latest_first ->
          ( C.Workflow_loaded (latest, Error F.invalid_config),
            C.Request_canceled borrowed )
    in
    let half_closed = send ~now:100 changed_again first in
    no_command "Invalid preflight still joins the borrowed loader" poll
      half_closed;
    let tick = send ~now:100 half_closed (C.Poll_due poll_id) in
    let next_id, _ =
      choose "Busy preflight retains cadence" poll tick.commands
    in
    no_command "Busy preflight tick cannot overlap tracker reads" tracker tick;
    let closed = send ~now:200 tick last in
    no_command "Closure cannot replace retained cadence" poll closed;
    no_command "Invalid preflight admits no candidates" tracker closed;
    no_command "Invalid preflight cannot immediately reload" load closed;
    let next = send ~now:200 closed (C.Poll_due next_id) in
    let _, due = choose "Next cadence tick paces polling" poll next.commands in
    Alcotest.check Alcotest.int "Cadence uses last-good interval" 0
      (Clock.Pure.compare due (F.instant 205))
  in
  List.iter check [ Old_first; Latest_first ]

let keyed_retry_closure () =
  let second = F.issue ~state:"Doing" ~id:"opaque-b" ~identifier:"CORE-2" () in
  let started = cycle ~issues:[ issue_a; second ] (startup F.A) in
  let first_run = run "opaque-a" started in
  let second_run = run "opaque-b" started in
  let waiting = close_worker started first_run Agent_runner.Succeeded in
  let waiting = close_worker ~now:1 waiting second_run Agent_runner.Succeeded in
  let token =
    match owner "opaque-a" waiting with
    | C.Retry retry -> retry.retry
    | C.Worker _ | C.Cleaning _ -> Alcotest.fail "First retry missing"
  in
  let reading =
    send ~now:1000 waiting (C.Retry_due (Issue.id issue_a, token))
  in
  let superseded = choose "Retry read missing" tracker reading.commands in
  let changed = send reading C.Workflow_changed in
  let selected = choose "Repair load missing" load changed.commands in
  let repaired =
    send changed (C.Workflow_loaded (selected, Ok (F.config F.A)))
  in
  let closed =
    send ~now:1100 repaired (C.Request_canceled (request_id superseded))
  in
  Alcotest.check Alcotest.int "Only matched retry produces an effect" 1
    (List.length closed.commands);
  let reread = choose "Matched retry reread missing" tracker closed.commands in
  (match reread with
  | T.Ids { ids; _ } ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "Closure wakes only its issue" [ "opaque-a" ]
        (List.map Issue_id.text (Issue_id.Set.elements ids))
  | T.States _ -> Alcotest.fail "Retry closure must reread its issue");
  Alcotest.check Alcotest.bool "Unrelated overdue retry awaits its keyed timer"
    true
    (match owner "opaque-b" closed with
    | C.Retry { phase = C.Waiting _; _ } -> true
    | C.Retry { phase = C.Refreshing | C.Parked; _ } | C.Worker _ | C.Cleaning _
      -> false)

let fault_context () =
  let fault_issue = function
    | C.Config_failure _ | C.Tracker_failure _ -> None
    | C.Issue_tracker_failure (issue, _)
    | C.Attempt_failure (issue, _)
    | C.Attempt_timeout (issue, _)
    | C.Attempt_cancel_error (issue, _)
    | C.Planning_failure (issue, _)
    | C.Cleanup_failure (issue, _)
    | C.Lifecycle_failure (issue, _) -> Some issue
    | C.Attempt_stalled issue -> Some issue
  in
  let context = function
    | C.Report fault -> fault_issue fault
    | C.Load_workflow _
    | C.Read_tracker _
    | C.Start_worker _
    | C.Stop_worker _
    | C.Continue_worker _
    | C.Remove_workspace _
    | C.Cancel_request _
    | C.Arm_poll _
    | C.Cancel_poll _
    | C.Arm_retry _
    | C.Cancel_retry _ -> None
  in
  let check expected harness =
    let issue =
      choose "Fault lost its issue context" context harness.commands
    in
    Alcotest.check Alcotest.string "Fault retains current identifier"
      (Issue_identifier.text (Issue.identifier expected))
      (Issue_identifier.text (Issue.identifier issue));
    Alcotest.check Alcotest.string "Fault retains current title"
      (Issue.title expected) (Issue.title issue)
  in
  let terminal =
    F.issue ~state:"Done" ~id:"opaque-clean" ~identifier:"CORE-99"
      ~title:"Current cleanup" ()
  in
  let cleaning = respond_first (initial F.A) [ terminal ] in
  let cleanup = choose "Cleanup missing" removal cleaning.commands in
  let released =
    send cleaning
      (C.Workspace_removed
         ( cleanup.request_id,
           Error (Workspace_manager.Filesystem_error F.diagnostic) ))
  in
  Alcotest.check Alcotest.int "Cleanup owner released" 0
    (List.length (owners released));
  check terminal released;
  let started = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" started in
  let reading = send started C.Refresh_requested in
  let read = choose "Reconciliation missing" tracker reading.commands in
  let latest =
    F.issue ~state:"Canceled" ~id:"opaque-a" ~identifier:"RENAMED"
      ~title:"Latest attempt" ()
  in
  let stopping = respond reading read (F.reply [ latest ]) in
  let released =
    close_worker stopping request
      (Agent_runner.Failed (Agent_runner.Response_error F.diagnostic))
  in
  Alcotest.check Alcotest.int "Stopped attempt owner released" 0
    (List.length (owners released));
  check latest released;
  let succeeded = close_worker started request Agent_runner.Succeeded in
  let token =
    match owner "opaque-a" succeeded with
    | C.Retry retry -> retry.retry
    | C.Worker _ | C.Cleaning _ -> Alcotest.fail "Retry missing"
  in
  let reading =
    send ~now:1000 succeeded (C.Retry_due (Issue.id issue_a, token))
  in
  let read = choose "Retry read missing" tracker reading.commands in
  let failed = respond reading read (Error F.tracker_error) in
  check issue_a failed

let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let thread = checked (Thread_id.parse "thread-core")
let first_turn = checked (Turn_id.parse "turn-a")
let next_turn = checked (Turn_id.parse "turn-b")
let first_session = checked (Session_id.parse "thread-core-turn-a")
let next_session = checked (Session_id.parse "thread-core-turn-b")

let emit ?now ?emitted_at harness request sequence notice =
  let now = Option.value now ~default:harness.now in
  let emitted_at = Option.value emitted_at ~default:now in
  let sequence = checked (Positive_count.parse (string_of_int sequence)) in
  send ~now harness
    (C.Worker_progress
       {
         issue = Issue.id (F.Agent.issue request);
         run = F.Agent.run_id request;
         progress = F.Agent.progress ~sequence notice;
         emitted_at = F.instant emitted_at;
       })

let session harness request =
  let harness = emit harness request 1 F.Agent.Preparing in
  let harness =
    F.with_path (F.Agent.workspace request) (fun path ->
        emit harness request 2 (F.Agent.Workspace_ready path))
  in
  let harness = emit harness request 3 F.Agent.Rendering in
  let harness = emit harness request 4 F.Agent.Starting in
  emit harness request 5
    (F.Agent.Protocol
       (Agent_runner.Session_started
          { session = first_session; thread; turn = first_turn }))

let completed_turn harness request sequence session turn =
  emit harness request sequence
    (F.Agent.Protocol (Agent_runner.Turn_completed { session; turn }))

let continue harness request turn =
  send harness
    (C.Worker_continue
       (Issue.id (F.Agent.issue request), F.Agent.run_id request, turn))

let continuation = function
  | C.Continue_worker (issue, run, turn, answer) ->
      Some (issue, run, turn, answer)
  | C.Load_workflow _
  | C.Read_tracker _
  | C.Start_worker _
  | C.Stop_worker _
  | C.Remove_workspace _
  | C.Cancel_request _
  | C.Arm_poll _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let stopping = function
  | C.Stop_worker (_, _, reason) -> Some reason
  | C.Load_workflow _
  | C.Read_tracker _
  | C.Start_worker _
  | C.Continue_worker _
  | C.Remove_workspace _
  | C.Cancel_request _
  | C.Arm_poll _
  | C.Cancel_poll _
  | C.Arm_retry _
  | C.Cancel_retry _
  | C.Report _ -> None

let continuation_serialization () =
  let started = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" started in
  let active = session started request in
  let older = send active C.Refresh_requested in
  let old_read = choose "Older reconciliation missing" tracker older.commands in
  let completed = completed_turn older request 6 first_session first_turn in
  running 1 completed;
  no_command "Protocol terminal cannot close worker" removal completed;
  let queued = continue completed request first_turn in
  no_command "Post-turn refresh waits older issue read" tracker queued;
  let repeated = continue queued request first_turn in
  Alcotest.check Alcotest.int "Duplicate continuation is identity" 0
    (List.length repeated.commands);
  let reading = respond repeated old_read (F.reply [ issue_a ]) in
  let fresh = choose "Fresh post-turn read missing" tracker reading.commands in
  Alcotest.check Alcotest.bool "Earlier read cannot satisfy turn" false
    (Request_id.equal (request_id old_read) (request_id fresh));
  no_command "Cycle waits post-turn refresh before preflight" load reading;
  let current =
    F.issue ~state:"Doing" ~title:"After turn" ~id:"opaque-a"
      ~identifier:"CORE-1" ()
  in
  let answered = respond reading fresh (F.reply [ current ]) in
  let _, run, turn, answer =
    choose "Continuation answer missing" continuation answered.commands
  in
  Alcotest.check Alcotest.bool "Answer fences current run" true
    (Run_id.equal run (F.Agent.run_id request));
  Alcotest.check Alcotest.bool "Answer fences completed turn" true
    (Turn_id.equal turn first_turn);
  (match answer with
  | Ok (Agent_runner.Continue issue) ->
      Alcotest.check Alcotest.string "Refreshed current issue" "After turn"
        (Issue.title issue)
  | Ok Agent_runner.Stop | Error _ ->
      Alcotest.fail "Active refresh must continue");
  let repeated = continue answered request first_turn in
  no_command "Answered turn cannot reread" tracker repeated;
  no_command "Answered turn cannot reply twice" continuation repeated;
  let changed = send repeated C.Workflow_changed in
  let id =
    choose "Continuation authority reload missing" load changed.commands
  in
  let changed = send changed (C.Workflow_loaded (id, Ok (F.config F.B))) in
  let next =
    emit changed request 7
      (F.Agent.Protocol
         (Agent_runner.Turn_started { session = next_session; turn = next_turn }))
  in
  let next = completed_turn next request 8 next_session next_turn in
  let next = continue next request next_turn in
  let next_read =
    choose "Distinct turn refresh missing" tracker next.commands
  in
  Alcotest.check Alcotest.bool "Next turn keeps original launch binding" true
    (T.equal (request_binding next_read) (F.Config.tracker (F.config F.A)));
  Alcotest.check Alcotest.bool
    "Latest credentials cannot replace launch authority" false
    (T.equal (request_binding next_read) (F.Config.tracker (F.config F.B)))

let continuation_epoch () =
  let started = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" started in
  let active =
    completed_turn (session started request) request 6 first_session first_turn
  in
  let reading = continue active request first_turn in
  let stale = choose "Continuation read missing" tracker reading.commands in
  let changed = send reading C.Workflow_changed in
  let id = choose "Reload missing" load changed.commands in
  let changed =
    send changed (C.Workflow_loaded (id, Ok (F.config F.New_policy)))
  in
  no_command "Canceled read retains custody" tracker changed;
  let closed =
    respond changed stale
      (F.reply [ F.issue ~state:"Done" ~id:"opaque-a" ~identifier:"CORE-1" () ])
  in
  no_command "Superseded terminal cannot stop worker" stopping closed;
  no_command "Superseded read cannot answer continuation" continuation closed;
  let fresh =
    choose "Current policy continuation reread missing" tracker closed.commands
  in
  Alcotest.check Alcotest.bool "Superseded read gets a new request" false
    (Request_id.equal (request_id stale) (request_id fresh));
  let terminal =
    F.issue ~state:"Closed" ~id:"opaque-a" ~identifier:"CORE-1" ()
  in
  let stopped = respond closed fresh (F.reply [ terminal ]) in
  running 1 stopped;
  (match choose "Terminal answer missing" continuation stopped.commands with
  | _, _, _, Ok Agent_runner.Stop -> ()
  | _, _, _, (Ok (Agent_runner.Continue _) | Error _) ->
      Alcotest.fail "New terminal policy must stop");
  let shutdown = send stopped C.Shutdown in
  let closed = close_worker shutdown request Agent_runner.Succeeded in
  running 0 closed;
  ignore (choose "Terminal cleanup survives shutdown" removal closed.commands)

let accepted_usage () =
  let started = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" started in
  let active = session started request in
  let usage input output total =
    Usage.make
      ~input:(checked (Count.parse input))
      ~output:(checked (Count.parse output))
      ~total:(checked (Count.parse total))
  in
  let report harness sequence absolute =
    emit harness request sequence
      (F.Agent.Protocol
         (Agent_runner.Usage_report { thread; turn = first_turn; absolute }))
  in
  let observed = report active 6 (usage "5" "7" "20") in
  let observed = report observed 7 (usage "2" "9" "15") in
  let stale = report observed 6 (usage "999" "999" "999") in
  let rates = checked (Json.parse "{\"remaining\":null}") in
  let observed =
    emit stale request 8 (F.Agent.Protocol (Agent_runner.Rate_limits rates))
  in
  let check harness =
    let totals = (projection harness).total_usage in
    Alcotest.check Alcotest.string "Joined input" "5"
      (Count.decimal (Usage.input totals));
    Alcotest.check Alcotest.string "Joined output" "9"
      (Count.decimal (Usage.output totals));
    Alcotest.check Alcotest.string "Joined total" "20"
      (Count.decimal (Usage.total totals));
    Alcotest.check Alcotest.bool "Rate observation persists" true
      ((projection harness).latest_rate_limits = Some rates)
  in
  check observed;
  let closed = close_worker observed request Agent_runner.Succeeded in
  check closed;
  check (close_worker closed request Agent_runner.Succeeded)

let configured config =
  let state, commands = C.create ~now:(F.instant 0) config in
  let harness = { state; now = 0; commands; history = commands } in
  respond_first harness []

let retired_continuation_barrier () =
  let started = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" started in
  let active =
    completed_turn (session started request) request 6 first_session first_turn
  in
  let reading = continue active request first_turn in
  let unfinished =
    choose "Continuation read missing" tracker reading.commands
  in
  let retired =
    close_worker reading request
      (Agent_runner.Failed (Agent_runner.Response_error F.diagnostic))
  in
  let retry =
    match owner "opaque-a" retired with
    | C.Retry retry -> retry.retry
    | C.Worker _ | C.Cleaning _ ->
        Alcotest.fail "Failed run must wait for retry"
  in
  let due = send ~now:1000 retired (C.Retry_due (Issue.id issue_a, retry)) in
  no_command "Retry cannot cross retained continuation custody" tracker due;
  let closed = send due (C.Request_canceled (request_id unfinished)) in
  let refreshed =
    choose "Closed continuation wakes its due retry" tracker closed.commands
  in
  let restarted = respond closed refreshed (F.reply [ issue_a ]) in
  let next =
    choose "Retry starts after read closure" worker restarted.commands
  in
  Alcotest.check Alcotest.bool "Closed prior run gets a fresh generation" false
    (Run_id.equal (F.Agent.run_id request) (F.Agent.run_id next))

let stall_closure () =
  let config = F.with_stall ~milliseconds:10 F.A in
  let started = cycle ~config ~issues:[ issue_a ] (configured config) in
  let request = run "opaque-a" started in
  let preparing = emit ~now:9 started request 1 F.Agent.Preparing in
  let token, _ = choose "Poll missing" poll started.history in
  let equal = send ~now:10 preparing (C.Poll_due token) in
  no_command "Stall boundary is strict" stopping equal;
  let token, _ = choose "Next poll missing" poll equal.commands in
  let equal = close_reads ~config ~profile:F.A ~issues:[ issue_a ] equal in
  let stalled = send ~now:15 equal (C.Poll_due token) in
  Alcotest.check Alcotest.bool "Preparation does not reset protocol silence"
    true
    (choose "Stall interruption missing" stopping stalled.commands
    = Agent_runner.Stall);
  running 1 stalled;
  let read = choose "Stall reconciliation missing" tracker stalled.commands in
  let terminal = F.issue ~state:"Done" ~id:"opaque-a" ~identifier:"CORE-1" () in
  let refined = respond stalled read (F.reply [ terminal ]) in
  no_command "Cleanup upgrade does not issue another interruption" stopping
    refined;
  let closed = close_worker refined request Agent_runner.Succeeded in
  running 0 closed;
  ignore
    (choose "Terminal upgrade requires cleanup after close" removal
       closed.commands);
  no_command "Cleanup upgrade cannot retry"
    (function
      | C.Arm_retry _ -> Some ()
      | C.Load_workflow _
      | C.Read_tracker _
      | C.Start_worker _
      | C.Stop_worker _
      | C.Continue_worker _
      | C.Remove_workspace _
      | C.Cancel_request _
      | C.Arm_poll _
      | C.Cancel_poll _
      | C.Cancel_retry _
      | C.Report _ -> None)
    closed

let stall_activity () =
  let config = F.with_stall ~milliseconds:10 F.A in
  let started = cycle ~config ~issues:[ issue_a ] (configured config) in
  let request = run "opaque-a" started in
  let active = session started request in
  let active =
    emit ~now:8 active request 6
      (F.Agent.Protocol
         (Agent_runner.Output
            {
              session = first_session;
              event_name = "delta";
              message = Some "progress";
            }))
  in
  let token, _ = choose "Poll missing" poll started.history in
  let checked = send ~now:10 active (C.Poll_due token) in
  no_command "Accepted protocol activity resets silence" stopping checked;
  let token, _ = choose "Next poll missing" poll checked.commands in
  let checked = close_reads ~config ~profile:F.A ~issues:[ issue_a ] checked in
  let equal = send ~now:18 checked (C.Poll_due token) in
  no_command "Activity boundary is strict" stopping equal;
  let token, _ = choose "Final poll missing" poll equal.commands in
  let equal = close_reads ~config ~profile:F.A ~issues:[ issue_a ] equal in
  let stale =
    emit ~now:19 equal request 5
      (F.Agent.Protocol
         (Agent_runner.Output
            { session = first_session; event_name = "old"; message = None }))
  in
  let stalled = send ~now:23 stale (C.Poll_due token) in
  ignore
    (choose "Stale progress cannot postpone stall" stopping stalled.commands);
  let closed = close_worker stalled request Agent_runner.Succeeded in
  ignore
    (choose "Stall retains retry disposition after racing success"
       (function
         | C.Arm_retry (_, _, due) -> Some due
         | C.Load_workflow _
         | C.Read_tracker _
         | C.Start_worker _
         | C.Stop_worker _
         | C.Continue_worker _
         | C.Remove_workspace _
         | C.Cancel_request _
         | C.Arm_poll _
         | C.Cancel_poll _
         | C.Cancel_retry _
         | C.Report _ -> None)
       closed.commands)

let stall_during_read () =
  let config = F.with_stall ~milliseconds:10 F.A in
  let started = cycle ~config ~issues:[ issue_a ] (configured config) in
  let request = run "opaque-a" started in
  let active = session started request in
  let token, _ = choose "Poll missing" poll started.history in
  let reading = send ~now:5 active (C.Poll_due token) in
  ignore (choose "Reconciliation read missing" tracker reading.commands);
  no_command "Worker is not silent beyond the limit yet" stopping reading;
  let token, due =
    choose "Pending tracker read must retain the cadence timer" poll
      reading.commands
  in
  Alcotest.check Alcotest.bool "Next tick retains configured cadence" true
    (Clock.Pure.compare due (F.instant 10) = 0);
  let equal = send ~now:10 reading (C.Poll_due token) in
  no_command "Stall equality stays strict during a pending read" stopping equal;
  no_command "Cadence cannot overlap reconciliation reads" tracker equal;
  let token, _ =
    choose "Active cycle must rearm its timer" poll equal.commands
  in
  let stalled = send ~now:15 equal (C.Poll_due token) in
  Alcotest.check Alcotest.bool "Pending read cannot suppress a stall" true
    (choose "Silent worker interruption missing" stopping stalled.commands
    = Agent_runner.Stall);
  no_command "Stall tick cannot overlap the retained read" tracker stalled;
  running 1 stalled;
  match owner "opaque-a" stalled with
  | C.Worker { phase = C.Stopping; _ } -> ()
  | C.Worker { phase = C.Starting | C.Active; _ } | C.Retry _ | C.Cleaning _ ->
      Alcotest.fail "Stall must retain the worker until its scope closes"

let stall_on_refresh () =
  let config = F.with_stall ~milliseconds:10 F.A in
  let started = cycle ~config ~issues:[ issue_a ] (configured config) in
  let request = run "opaque-a" started in
  let active = session started request in
  let refreshed =
    List.fold_left
      (fun harness now ->
        let next = send ~now harness C.Refresh_requested in
        no_command "Refresh before strict silence cutoff cannot stop" stopping
          next;
        close_reads ~config ~profile:F.A ~issues:[ issue_a ] next)
      active [ 1; 4; 7; 10 ]
  in
  let stalled = send ~now:13 refreshed C.Refresh_requested in
  Alcotest.check Alcotest.bool "Repeated refreshes cannot starve stall checks"
    true
    (choose "Explicit refresh must interrupt a silent worker" stopping
       stalled.commands
    = Agent_runner.Stall);
  running 1 stalled

type continuation_close = Cancel_receipt | Tracker_receipt

let stall_deferred_reconcile () =
  List.iter
    (fun closing ->
      let config = F.with_stall ~milliseconds:10 F.A in
      let latest = F.with_stall ~milliseconds:10 F.B in
      let started = cycle ~config ~issues:[ issue_a ] (configured config) in
      let request = run "opaque-a" started in
      let active =
        completed_turn (session started request) request 6 first_session
          first_turn
      in
      let loading = send active C.Workflow_changed in
      let id = choose "Reload missing" load loading.commands in
      let loaded = send loading (C.Workflow_loaded (id, Ok latest)) in
      let reading = continue loaded request first_turn in
      let retained =
        choose "Continuation read missing" tracker reading.commands
      in
      let token, _ = choose "Reloaded poll missing" poll loaded.commands in
      let stalled = send ~now:15 reading (C.Poll_due token) in
      ignore (choose "Stall interruption missing" stopping stalled.commands);
      no_command "Reconciliation waits for continuation resource closure"
        tracker stalled;
      let terminal =
        F.issue ~state:"Done" ~id:"opaque-a" ~identifier:"CORE-1" ()
      in
      let input =
        match closing with
        | Cancel_receipt -> C.Request_canceled (request_id retained)
        | Tracker_receipt ->
            C.Tracker_completed (request_id retained, F.reply [ terminal ])
      in
      let closed = send stalled input in
      no_command "Canceled continuation cannot answer or refine the worker"
        continuation closed;
      no_command "Canceled terminal data cannot remove an open worker workspace"
        removal closed;
      let fresh =
        choose "Closed continuation must wake deferred reconciliation" tracker
          closed.commands
      in
      Alcotest.check Alcotest.bool
        "Deferred read keeps the original worker binding" true
        (T.equal (request_binding fresh) (F.Config.tracker config));
      Alcotest.check Alcotest.bool
        "Deferred read does not borrow the latest binding" false
        (T.equal (request_binding fresh) (F.Config.tracker latest));
      let refined = respond closed fresh (F.reply [ terminal ]) in
      no_command "Terminal reply waits for worker resource closure" removal
        refined;
      no_command "Terminal refinement cannot issue a second interruption"
        stopping refined;
      let stopping = send refined C.Shutdown in
      let finished = close_worker stopping request Agent_runner.Succeeded in
      ignore
        (choose "Deferred terminal reconciliation requires cleanup after close"
           removal finished.commands);
      running 0 finished)
    [ Cancel_receipt; Tracker_receipt ]

type worker_close_order = Before_read | During_reconcile

let stall_closed_before_read () =
  List.iter
    (fun (closing, order) ->
      let config = F.with_stall ~milliseconds:10 F.A in
      let latest = F.with_stall ~milliseconds:10 F.B in
      let started = cycle ~config ~issues:[ issue_a ] (configured config) in
      let request = run "opaque-a" started in
      let active =
        completed_turn (session started request) request 6 first_session
          first_turn
      in
      let loading = send active C.Workflow_changed in
      let id = choose "Reload missing" load loading.commands in
      let loaded = send loading (C.Workflow_loaded (id, Ok latest)) in
      let reading = continue loaded request first_turn in
      let retained =
        choose "Continuation read missing" tracker reading.commands
      in
      let token, _ = choose "Reloaded poll missing" poll loaded.commands in
      let stalled = send ~now:15 reading (C.Poll_due token) in
      ignore (choose "Stall interruption missing" stopping stalled.commands);
      let terminal =
        F.issue ~state:"Done" ~id:"opaque-a" ~identifier:"CORE-1" ()
      in
      let input =
        match closing with
        | Cancel_receipt -> C.Request_canceled (request_id retained)
        | Tracker_receipt ->
            C.Tracker_completed (request_id retained, F.reply [ terminal ])
      in
      let retire harness =
        let retired = close_worker harness request Agent_runner.Succeeded in
        running 0 retired;
        let retry =
          match owner "opaque-a" retired with
          | C.Retry retry -> retry.retry
          | C.Worker _ | C.Cleaning _ ->
              Alcotest.fail "Stalled closed worker must retain its retry claim"
        in
        let overdue =
          send ~now:1000 retired (C.Retry_due (Issue.id issue_a, retry))
        in
        no_command "Retry cannot cross reconciliation resource custody" tracker
          overdue;
        overdue
      in
      let close_read harness =
        let closed = send harness input in
        no_command "Canceled data cannot clean the worker" removal closed;
        no_command "Canceled data cannot answer the worker" continuation closed;
        let fresh =
          choose "Closed continuation must reconcile before relaunch" tracker
            closed.commands
        in
        (closed, fresh)
      in
      let closed, fresh =
        match order with
        | Before_read -> close_read (retire stalled)
        | During_reconcile ->
            let closed, fresh = close_read stalled in
            (retire closed, fresh)
      in
      Alcotest.check Alcotest.bool "Retired read keeps original worker binding"
        true
        (T.equal (request_binding fresh) (F.Config.tracker config));
      Alcotest.check Alcotest.bool
        "Retired read cannot use replacement credentials" false
        (T.equal (request_binding fresh) (F.Config.tracker latest));
      let refined = respond closed fresh (F.reply [ terminal ]) in
      ignore
        (choose "Fresh terminal read cleans the retired worker" removal
           refined.commands);
      no_command "Terminal read cannot relaunch the retired worker" worker
        refined;
      no_command "Terminal read cannot issue another interruption" stopping
        refined;
      running 0 refined;
      match owner "opaque-a" refined with
      | C.Cleaning _ -> ()
      | C.Worker _ | C.Retry _ ->
          Alcotest.fail "Fresh terminal read must reserve workspace cleanup")
    [
      (Cancel_receipt, Before_read);
      (Tracker_receipt, Before_read);
      (Cancel_receipt, During_reconcile);
      (Tracker_receipt, During_reconcile);
    ]

let deferred_retry_deadline () =
  let config = F.with_stall ~milliseconds:10 F.A in
  let started = cycle ~config ~issues:[ issue_a ] (configured config) in
  let request = run "opaque-a" started in
  let active =
    completed_turn (session started request) request 6 first_session first_turn
  in
  let reading = continue active request first_turn in
  let retained = choose "Continuation read missing" tracker reading.commands in
  let token, _ = choose "Startup poll missing" poll started.history in
  let stalled = send ~now:15 reading (C.Poll_due token) in
  let retired = close_worker stalled request Agent_runner.Succeeded in
  let waiting harness =
    match owner "opaque-a" harness with
    | C.Retry { retry; phase = C.Waiting due; _ } -> (retry, due)
    | C.Worker _ | C.Cleaning _ | C.Retry { phase = C.Refreshing | C.Parked; _ }
      ->
        Alcotest.fail "Deferred reconciliation must retain the waiting deadline"
  in
  let retry, due = waiting retired in
  let closed =
    send ~now:16 retired (C.Request_canceled (request_id retained))
  in
  let fresh =
    choose "Deferred reconciliation missing" tracker closed.commands
  in
  let refreshed =
    send ~now:17 closed
      (C.Tracker_completed (request_id fresh, F.reply [ issue_a ]))
  in
  no_command "Nonterminal reconciliation cannot bypass retry delay" worker
    refreshed;
  let current, current_due = waiting refreshed in
  Alcotest.check Alcotest.bool "Nonterminal reply preserves the retry receipt"
    true
    (Retry_id.equal retry current);
  Alcotest.check Alcotest.int "Nonterminal reply preserves backoff deadline" 0
    (Clock.Pure.compare due current_due);
  let ready = close_reads ~config ~profile:F.A ~issues:[ issue_a ] refreshed in
  let loading = send ~now:1000 ready (C.Retry_due (Issue.id issue_a, retry)) in
  ignore
    (choose "Due retry refreshes after reconciliation closure" tracker
       loading.commands);
  no_command "Due retry waits for its own fresh read" worker loading

let operator_snapshot () =
  let harness = cycle ~issues:[ issue_a ] (startup F.A) in
  let request = run "opaque-a" harness in
  let wall = checked (Utc.parse "2030-01-01T00:00:10Z") in
  let sample = { Clock.Pure.monotonic = F.instant 5000; wall } in
  let read harness = checked (C.snapshot ~sample harness.state) in
  let row snapshot =
    match (Snapshot.data snapshot).Snapshot.running with
    | [ row ] -> row
    | _ -> Alcotest.fail "one canonical worker expected"
  in
  let initial = row (read harness) in
  Alcotest.(check bool)
    "pre-acquisition workspace is absent" true
    (Option.is_none initial.Snapshot.workspace);
  Alcotest.(check bool)
    "initial worker has no session" true
    (initial.Snapshot.phase = Snapshot.Awaiting);
  let harness = session harness request in
  let before = projection harness in
  let snapshot = read harness in
  let current = row snapshot in
  Alcotest.(check (pair int int))
    "derived counts" (1, 0) (Snapshot.counts snapshot);
  Alcotest.(check string)
    "fresh elapsed interval" "5"
    (Seconds.decimal current.Snapshot.seconds_running);
  let expected_start = checked (Utc.parse "2030-01-01T00:00:05Z") in
  Alcotest.(check (option int))
    "start uses the same affine sample" (Some 0)
    (Option.map
       (fun value -> Utc.compare value expected_start)
       current.Snapshot.started_at);
  F.with_path (F.Agent.workspace request) (fun path ->
      Alcotest.(check (option string))
        "only accepted acquired workspace"
        (Some (F.Path.display path))
        current.Snapshot.workspace);
  (match current.Snapshot.phase with
  | Snapshot.Streaming session ->
      Alcotest.(check string)
        "canonical session"
        (Session_id.text first_session)
        (Session_id.text session.Snapshot.id);
      Alcotest.(check (option int))
        "event uses the same sample" (Some 0)
        (Option.map
           (fun value -> Utc.compare value expected_start)
           session.Snapshot.last_event_at)
  | Snapshot.Awaiting
  | Snapshot.Preparing
  | Snapshot.Workspace_ready
  | Snapshot.Rendering
  | Snapshot.Starting
  | Snapshot.Between_turns _
  | Snapshot.Stopping_before_session
  | Snapshot.Stopping_session _ ->
      Alcotest.fail "acquired session must be streaming");
  ignore (read harness);
  Alcotest.(check bool)
    "queries cannot change reducer facts" true
    (before = projection harness);
  let finished =
    close_worker ~now:1000 harness request Agent_runner.Succeeded
  in
  let snapshot = read finished in
  Alcotest.(check (pair int int))
    "closed worker becomes retry" (0, 1) (Snapshot.counts snapshot);
  Alcotest.(check string)
    "ended interval retained once" "1"
    (Seconds.decimal (Snapshot.data snapshot).Snapshot.seconds_running);
  (match (Snapshot.data snapshot).Snapshot.retrying with
  | [ { Snapshot.phase = Snapshot.Waiting (Some due); error = None; _ } ] ->
      Alcotest.(check int)
        "retry deadline projects from this sample" 0
        (Utc.compare due (checked (Utc.parse "2030-01-01T00:00:07Z")))
  | [] | _ :: _ :: _
  | [ { Snapshot.phase = Snapshot.Waiting None; _ } ]
  | [ { Snapshot.phase = Snapshot.Refreshing | Snapshot.Parked; _ } ]
  | [ { Snapshot.phase = Snapshot.Waiting (Some _); error = Some _; _ } ] ->
      Alcotest.fail "continuation has one waiting retry without an error");
  let halted = send finished C.Shutdown in
  Alcotest.(check bool)
    "released issue is absent" true
    (Option.is_none (Snapshot.find (read halted) (Issue.identifier issue_a)))

let snapshot_read_failure () =
  let second =
    F.issue ~state:"Doing" ~id:"another-id" ~identifier:"CORE-1" ()
  in
  let harness = cycle ~issues:[ issue_a; second ] (startup F.A) in
  let before = projection harness in
  let sample =
    {
      Clock.Pure.monotonic = F.instant 10;
      wall = checked (Utc.parse "2030-01-01T00:00:00Z");
    }
  in
  Alcotest.(check bool)
    "ambiguous route projection is rejected" true
    (Result.is_error (C.snapshot ~sample harness.state));
  Alcotest.(check bool)
    "projection rejection leaves scheduling intact" true
    (before = projection harness)

let tests =
  [
    Alcotest.test_case "fresh operator snapshot derives canonical lifecycle"
      `Quick operator_snapshot;
    Alcotest.test_case "read projection failure preserves scheduling" `Quick
      snapshot_read_failure;
    Alcotest.test_case "startup cleanup closure barrier" `Quick startup_barrier;
    Alcotest.test_case "sorted admission and pure rejection" `Quick admission;
    Alcotest.test_case "exact retry and retired worker fencing" `Quick retry_due;
    Alcotest.test_case "original-binding reconciliation barrier" `Quick
      grouped_reconciliation;
    Alcotest.test_case "superseded retry parks and repairs" `Quick parked_reload;
    Alcotest.test_case "startup reload fences cleanup authority" `Quick
      startup_reload_fence;
    Alcotest.test_case "shutdown awaits closed resource custody" `Quick
      shutdown_drain;
    Alcotest.test_case "scope drain fences reused issue IDs" `Quick scope_drain;
    Alcotest.test_case "required cleanup absorbs shutdown" `Quick
      cleanup_absorbs_shutdown;
    Alcotest.test_case "latest load fulfills closed cycle preflight" `Quick
      replace_preflight;
    Alcotest.test_case "canceled selected load restores prior validation" `Quick
      canceled_load_readiness;
    Alcotest.test_case "invalid candidate replacement paces next poll" `Quick
      invalid_candidate_reload;
    Alcotest.test_case "bootstrap joins superseded loader custody" `Quick
      startup_loader_custody;
    Alcotest.test_case "final bootstrap loader arms one poll" `Quick
      startup_final_loader;
    Alcotest.test_case "borrowed preflight joins canceled loader" `Quick
      borrowed_preflight_custody;
    Alcotest.test_case "retry closure wakes only its keyed owner" `Quick
      keyed_retry_closure;
    Alcotest.test_case "fault context survives owner release" `Quick
      fault_context;
    Alcotest.test_case "post-turn read serializes and answers once" `Quick
      continuation_serialization;
    Alcotest.test_case "continuation rereads after policy epoch" `Quick
      continuation_epoch;
    Alcotest.test_case "accepted usage retires once" `Quick accepted_usage;
    Alcotest.test_case "retired continuation custody gates retry" `Quick
      retired_continuation_barrier;
    Alcotest.test_case "stall retains custody and cleanup absorbs" `Quick
      stall_closure;
    Alcotest.test_case "stall follows accepted protocol activity" `Quick
      stall_activity;
    Alcotest.test_case "pending tracker reads retain stall cadence" `Quick
      stall_during_read;
    Alcotest.test_case "repeated explicit refreshes cannot starve stalls" `Quick
      stall_on_refresh;
    Alcotest.test_case
      "closed continuation wakes original-binding reconciliation" `Quick
      stall_deferred_reconcile;
    Alcotest.test_case
      "closed worker retains deferred original-binding reconciliation" `Quick
      stall_closed_before_read;
    Alcotest.test_case "nonterminal deferred reply preserves retry deadline"
      `Quick deferred_retry_deadline;
  ]
