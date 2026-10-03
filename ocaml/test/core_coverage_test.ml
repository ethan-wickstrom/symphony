module F = Core_fixture
module C = F.Core
module T = Tracker_registry.Contract
open C

type harness = { state : C.state; now : int; commands : C.command list }

let read_budget = 16
let failure_count = 20

let send ?now harness input =
  let now = Option.value ~default:harness.now now in
  let state, commands =
    C.step harness.state (C.event ~now:(F.instant now) input)
  in
  { state; now; commands }

let one message = function
  | [ value ] -> value
  | [] | _ :: _ :: _ -> Alcotest.fail message

let tracker commands =
  List.filter_map
    (function
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
      | C.Report _ -> None)
    commands
  |> one "Expected one tracker request"

let starts commands =
  List.filter_map
    (function
      | C.Start_worker request -> Some request
      | C.Load_workflow _
      | C.Read_tracker _
      | C.Stop_worker _
      | C.Continue_worker _
      | C.Remove_workspace _
      | C.Cancel_request _
      | C.Arm_poll _
      | C.Cancel_poll _
      | C.Arm_retry _
      | C.Cancel_retry _
      | C.Report _ -> None)
    commands

let request_id = function
  | T.States { id; _ } | T.Ids { id; _ } -> id

let respond harness request issues =
  send harness (C.Tracker_completed (request_id request, F.reply issues))

let initial profile =
  let state, commands = C.create ~now:(F.instant 0) (F.config profile) in
  let harness = { state; now = 0; commands } in
  respond harness (tracker commands) []

let reply issues = function
  | T.Ids { ids; _ } ->
      List.filter (fun issue -> Issue_id.Set.mem (Issue.id issue) ids) issues
  | T.States { names; _ } ->
      List.filter (fun issue -> List.mem (Issue.state_key issue) names) issues

(* The finite fixture driver closes reads/loads only; workers remain explicit. *)
let drive ~profile ~issues harness =
  let rec loop budget pending harness observed =
    match pending with
    | [] -> { harness with commands = observed }
    | _ when budget = 0 -> Alcotest.fail "Read pipeline did not settle"
    | command :: remaining -> (
        let next =
          match command with
          | C.Load_workflow { id; _ } ->
              Some
                (send harness (C.Workflow_loaded (id, Ok (F.config profile))))
          | C.Read_tracker request ->
              Some (respond harness request (reply issues request))
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
        | None -> loop (budget - 1) remaining harness observed
        | Some next ->
            loop (budget - 1)
              (remaining @ next.commands)
              next (observed @ next.commands))
  in
  loop read_budget harness.commands harness harness.commands

let cycle ~profile ~issues harness =
  drive ~profile ~issues (send harness C.Refresh_requested)

let started_ids harness =
  List.map
    (fun request -> Issue_id.text (Issue.id (F.Agent.issue request)))
    (starts harness.commands)

let check_starts expected harness =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "Ordered launches" expected (started_ids harness)

let finish ?now harness request outcome =
  send ?now harness
    (C.Worker_finished
       (F.completed
          ~issue:(Issue.id (F.Agent.issue request))
          ~run:(F.Agent.run_id request) outcome))

let release harness requests =
  List.fold_left
    (fun harness request ->
      finish harness request
        (Agent_runner.Canceled
           { reason = Agent_runner.Host_shutdown; remote_error = None }))
    harness requests

let required_labels () =
  let issue labels id identifier =
    F.issue ~state:"Doing" ~labels ~id ~identifier ()
  in
  let absent = issue [] "absent" "CORE-0" in
  let partial = issue [ "ready" ] "partial" "CORE-1" in
  let mixed = issue [ "READY"; "REVIEWED" ] "mixed" "CORE-2" in
  let extra = issue [ "ready"; "reviewed"; "extra" ] "extra" "CORE-3" in
  let harness =
    cycle ~profile:F.Required
      ~issues:[ extra; partial; absent; mixed ]
      (initial F.Required)
  in
  check_starts [ "mixed"; "extra" ] harness;
  Alcotest.check Alcotest.int "Rejected labels acquire no claim" 2
    (List.length (C.project ~now:(F.instant harness.now) harness.state).owners);
  Alcotest.check Alcotest.bool "Label policy retains original binding" true
    (T.equal
       (F.Config.tracker (F.config F.A))
       (F.Config.tracker (F.config F.Required)))

let creation_order () =
  let issue ?created_at id identifier =
    F.issue ~state:"Doing" ?created_at ~id ~identifier ()
  in
  let oldest = issue ~created_at:"2024-01-01T00:00:00Z" "oldest" "CORE-4" in
  let tied_z = issue ~created_at:"2025-01-01T00:00:00Z" "tied-z" "CORE-9" in
  let tied_a = issue ~created_at:"2025-01-01T00:00:00Z" "tied-a" "CORE-1" in
  let undated = issue "undated" "CORE-0" in
  let first =
    cycle ~profile:F.A ~issues:[ undated; tied_z; tied_a; oldest ] (initial F.A)
  in
  check_starts [ "oldest"; "tied-a" ] first;
  let remaining = release first (starts first.commands) in
  let second = cycle ~profile:F.A ~issues:[ undated; tied_z ] remaining in
  check_starts [ "tied-z"; "undated" ] second

let todo_routing () =
  let id = "todo-route" in
  let make routing = F.issue ~routing ~id ~identifier:"CORE-1" () in
  let denied =
    cycle ~profile:F.A ~issues:[ make Issue.Unroutable ] (initial F.A)
  in
  check_starts [] denied;
  Alcotest.check Alcotest.int "Unroutable Todo stays unclaimed" 0
    (List.length (C.project ~now:(F.instant denied.now) denied.state).owners);
  let admitted =
    cycle ~profile:F.A ~issues:[ make Issue.Dispatchable ] denied
  in
  check_starts [ id ] admitted;
  let request = one "Expected routed Todo worker" (starts admitted.commands) in
  let revoked = cycle ~profile:F.A ~issues:[ make Issue.Unroutable ] admitted in
  check_starts [] revoked;
  let stops =
    List.filter_map
      (function
        | C.Stop_worker (issue, run, reason) -> Some (issue, run, reason)
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
        | C.Report _ -> None)
      revoked.commands
  in
  let stopped_issue, stopped_run, reason =
    one "Routing revoke must stop once" stops
  in
  Alcotest.check Alcotest.bool "Stop targets original worker" true
    (Issue_id.equal stopped_issue (Issue.id (F.Agent.issue request))
    && Run_id.equal stopped_run (F.Agent.run_id request));
  Alcotest.check Alcotest.bool "Routing stop reason" true
    (match reason with
    | Agent_runner.Cancel Agent_runner.Reconciliation -> true
    | Agent_runner.Cancel
        (Agent_runner.Scope_change | Agent_runner.Host_shutdown)
    | Agent_runner.Stall -> false);
  let closed = finish revoked request Agent_runner.Succeeded in
  Alcotest.check Alcotest.int "Revoke releases only after closure" 0
    (List.length (C.project ~now:(F.instant closed.now) closed.state).owners)

let retry_timer commands =
  List.filter_map
    (function
      | C.Arm_retry (issue, token, due) -> Some (issue, token, due)
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
    commands
  |> one "Expected one failure retry timer"

let check_waiting attempt token due harness =
  match
    one "Expected one retry owner"
      (C.project ~now:(F.instant harness.now) harness.state).owners
  with
  | C.Retry retry -> (
      Alcotest.check Alcotest.string "Exact retry attempt"
        (string_of_int attempt)
        (Count.decimal (Positive_count.count retry.attempt));
      Alcotest.check Alcotest.bool "Queued timer identity" true
        (Retry_id.equal token retry.retry);
      match retry.phase with
      | C.Waiting actual ->
          Alcotest.check Alcotest.int "Exact due instant" 0
            (Clock.Pure.compare actual due)
      | C.Refreshing | C.Parked -> Alcotest.fail "Retry must be waiting")
  | C.Worker _ | C.Cleaning _ -> Alcotest.fail "Failure must retain retry owner"

let reload profile harness =
  let changed = send harness C.Workflow_changed in
  let loads =
    List.filter_map
      (function
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
        | C.Report _ -> None)
      changed.commands
  in
  let id = one "Expected current workflow loader" loads in
  send changed (C.Workflow_loaded (id, Ok (F.config profile)))

let failure_backoff () =
  let current = F.issue ~state:"Doing" ~id:"repeated" ~identifier:"CORE-1" () in
  let harness =
    cycle ~profile:F.Growing_retry ~issues:[ current ] (initial F.Growing_retry)
  in
  let request = one "Expected first worker" (starts harness.commands) in
  let delay attempt =
    match attempt with
    | 1 -> 10000
    | 2 -> 20000
    | 3 -> 40000
    | 4 -> 45000
    | _ -> 40
  in
  let rec loop attempt harness request =
    let closed =
      finish ~now:(harness.now + 1) harness request
        (Agent_runner.Failed (Agent_runner.Response_error F.diagnostic))
    in
    let issue, token, due = retry_timer closed.commands in
    let due_ms = closed.now + delay attempt in
    Alcotest.check Alcotest.int "Current capped failure delay" 0
      (Clock.Pure.compare due (F.instant due_ms));
    check_waiting attempt token due closed;
    if attempt = failure_count then ()
    else
      let queued = if attempt = 4 then reload F.A closed else closed in
      check_waiting attempt token due queued;
      let reached = send ~now:due_ms queued (C.Retry_due (issue, token)) in
      let resumed = respond reached (tracker reached.commands) [ current ] in
      let request = one "Expected resumed worker" (starts resumed.commands) in
      (match F.Agent.attempt request with
      | Template.First -> Alcotest.fail "Retry must use a follow-up attempt"
      | Template.Follow_up count ->
          Alcotest.check Alcotest.string "Launch preserves retry attempt"
            (string_of_int attempt)
            (Count.decimal (Positive_count.count count)));
      loop (attempt + 1) resumed request
  in
  loop 1 harness request

let tests =
  [
    Alcotest.test_case "required labels gate actual admissions" `Quick
      required_labels;
    Alcotest.test_case "dispatch uses creation time and identifier" `Quick
      creation_order;
    Alcotest.test_case "Todo routing changes admission and reconciliation"
      `Quick todo_routing;
    Alcotest.test_case "exponential retry, changed cap and twenty failures"
      `Quick failure_backoff;
  ]
