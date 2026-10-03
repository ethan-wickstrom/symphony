module F = Core_fixture
module C = F.Core
module M = Core_model
module B = Core_bridge.Make (F.Agent) (C)

exception Difference = Core_bridge.Difference

let fail fmt = Printf.ksprintf (fun message -> raise (Difference message)) fmt

let bounded text =
  match int_of_string_opt text with
  | Some value -> value
  | None -> fail "Model fixture integer outside bounded domain: %s" text

let profiles = Core_bridge.profiles
let config = Core_bridge.config
let actual_issue = Core_bridge.actual_issue
let show_input = Core_bridge.show_input
let show_command = Core_bridge.show_command
let show_projection = Core_bridge.show_projection

type request_phase = In_flight | Canceling
type child_phase = Child_running | Child_stopping

type edge =
  | Load_edge of M.request * request_phase
  | Read_edge of M.request * request_phase
  | Remove_edge of M.request
  | Worker_edge of string * M.run * child_phase
  | Poll_edge of M.request * int
  | Retry_edge of string * M.retry_id * int

type request_close = Loaded | Read_closed | Removed | Canceled

let close_request kind id edges =
  List.filter
    (fun edge ->
      match edge with
      | Load_edge (other, phase) -> (
          match (kind, phase) with
          | Loaded, (In_flight | Canceling) | Canceled, Canceling -> id <> other
          | (Read_closed | Removed), (In_flight | Canceling)
          | Canceled, In_flight -> true)
      | Read_edge (other, phase) -> (
          match (kind, phase) with
          | Read_closed, (In_flight | Canceling) | Canceled, Canceling ->
              id <> other
          | (Loaded | Removed), (In_flight | Canceling) | Canceled, In_flight ->
              true)
      | Remove_edge other -> (
          match kind with
          | Removed -> id <> other
          | Loaded | Read_closed | Canceled -> true)
      | Worker_edge _ | Poll_edge _ | Retry_edge _ -> true)
    edges

let close_edges now input edges =
  match input with
  | M.Workflow_loaded (id, _) -> close_request Loaded id edges
  | M.Tracker_completed (id, _) -> close_request Read_closed id edges
  | M.Workspace_removed (id, _) -> close_request Removed id edges
  | M.Request_canceled id -> close_request Canceled id edges
  | M.Worker_finished (id, run, _) ->
      List.filter
        (function
          | Worker_edge (other_id, other_run, _) ->
              id <> other_id || run <> other_run
          | Load_edge _
          | Read_edge _
          | Remove_edge _
          | Poll_edge _
          | Retry_edge _ -> true)
        edges
  | M.Poll_due id ->
      List.filter
        (function
          | Poll_edge (other, due) -> id <> other || now < due
          | Load_edge _
          | Read_edge _
          | Remove_edge _
          | Worker_edge _
          | Retry_edge _ -> true)
        edges
  | M.Retry_due (id, retry) ->
      List.filter
        (function
          | Retry_edge (other_id, other_retry, due) ->
              id <> other_id || retry <> other_retry || now < due
          | Load_edge _
          | Read_edge _
          | Remove_edge _
          | Worker_edge _
          | Poll_edge _ -> true)
        edges
  | M.Refresh_requested | M.Workflow_changed | M.Worker_started _ | M.Shutdown
    -> edges

let register_edge edges = function
  | M.Load_workflow (id, _) -> edges @ [ Load_edge (id, In_flight) ]
  | M.Read_tracker read -> edges @ [ Read_edge (read.M.id, In_flight) ]
  | M.Remove_workspace (id, _) -> edges @ [ Remove_edge id ]
  | M.Start_worker worker ->
      edges @ [ Worker_edge (worker.M.issue.M.id, worker.M.run, Child_running) ]
  | M.Stop_worker (id, run, _) ->
      List.map
        (function
          | Worker_edge (other_id, other_run, _)
            when id = other_id && run = other_run ->
              Worker_edge (id, run, Child_stopping)
          | ( Load_edge _
            | Read_edge _
            | Remove_edge _
            | Worker_edge _
            | Poll_edge _
            | Retry_edge _ ) as edge -> edge)
        edges
  | M.Cancel_request id ->
      List.map
        (function
          | Load_edge (other, _) when id = other -> Load_edge (id, Canceling)
          | Read_edge (other, _) when id = other -> Read_edge (id, Canceling)
          | ( Load_edge _
            | Read_edge _
            | Remove_edge _
            | Worker_edge _
            | Poll_edge _
            | Retry_edge _ ) as edge -> edge)
        edges
  | M.Arm_poll (id, due) -> edges @ [ Poll_edge (id, due) ]
  | M.Cancel_poll id ->
      List.filter
        (function
          | Poll_edge (other, _) -> id <> other
          | Load_edge _
          | Read_edge _
          | Remove_edge _
          | Worker_edge _
          | Retry_edge _ -> true)
        edges
  | M.Arm_retry (id, retry, due) -> edges @ [ Retry_edge (id, retry, due) ]
  | M.Cancel_retry (id, retry) ->
      List.filter
        (function
          | Retry_edge (other_id, other_retry, _) ->
              id <> other_id || retry <> other_retry
          | Load_edge _
          | Read_edge _
          | Remove_edge _
          | Worker_edge _
          | Poll_edge _ -> true)
        edges
  | M.Report _ -> edges

type replay = { actual : C.state; bridge : B.t; edges : edge list }

let create profile =
  let now = F.instant 0 in
  let actual, commands = C.create ~now (F.config profile) in
  let bridge, expected =
    B.initial ~profile ~now ~commands ~projection:(C.project ~now actual)
  in
  B.check_quiescent bridge ~actual:(C.quiescent actual);
  { actual; bridge; edges = List.fold_left register_edge [] expected }

let actual_id id =
  match Issue_id.parse id with
  | Ok value -> value
  | Error error -> fail "%s" error

let outcome = function
  | M.Succeeded -> Agent_runner.Succeeded
  | M.Failed -> Agent_runner.Failed (Agent_runner.Turn_failed F.diagnostic)
  | M.Timed_out ->
      Agent_runner.Timed_out (Agent_runner.Response_deadline F.diagnostic)
  | M.Stalled -> Agent_runner.Stalled
  | M.Canceled ->
      Agent_runner.Canceled
        { reason = Agent_runner.Host_shutdown; remote_error = None }
  | M.Cancel_error ->
      Agent_runner.Canceled
        {
          reason = Agent_runner.Host_shutdown;
          remote_error = Some F.diagnostic;
        }

let input bridge ~profile = function
  | M.Poll_due q -> C.Poll_due (B.request bridge q)
  | M.Refresh_requested -> C.Refresh_requested
  | M.Workflow_changed -> C.Workflow_changed
  | M.Workflow_loaded (q, Ok _) ->
      C.Workflow_loaded (B.request bridge q, Ok (F.config profile))
  | M.Workflow_loaded (q, Error ()) ->
      C.Workflow_loaded (B.request bridge q, Error F.invalid_config)
  | M.Tracker_completed (q, Ok issues) ->
      C.Tracker_completed
        (B.request bridge q, F.reply (List.map actual_issue issues))
  | M.Tracker_completed (q, Error ()) ->
      C.Tracker_completed (B.request bridge q, Error F.tracker_error)
  | M.Worker_started (id, r) -> C.Worker_started (actual_id id, B.run bridge r)
  | M.Worker_finished (id, r, result) ->
      C.Worker_finished
        (F.completed ~issue:(actual_id id) ~run:(B.run bridge r)
           (outcome result))
  | M.Request_canceled q -> C.Request_canceled (B.request bridge q)
  | M.Retry_due (id, r) -> C.Retry_due (actual_id id, B.retry bridge r)
  | M.Workspace_removed (q, result) ->
      C.Workspace_removed
        ( B.request bridge q,
          match result with
          | Ok () -> Ok ()
          | Error () -> Error (Workspace_manager.Filesystem_error F.diagnostic)
        )
  | M.Shutdown -> C.Shutdown

let step ~profile ~now replay event =
  let instant = F.instant now in
  let envelope = input replay.bridge ~profile event in
  let actual, commands = C.step replay.actual (C.event ~now:instant envelope) in
  let bridge, decoded, expected =
    B.accept replay.bridge ~now:instant ~input:envelope ~commands
      ~projection:(C.project ~now:instant actual)
  in
  if decoded <> event then
    fail "Scripted/actual input differs: expected=%s actual=%s"
      (show_input event) (show_input decoded);
  B.check_quiescent bridge ~actual:(C.quiescent actual);
  {
    actual;
    bridge;
    edges =
      List.fold_left register_edge (close_edges now event replay.edges) expected;
  }

let edge_weight edges =
  List.fold_left
    (fun total -> function
      | Worker_edge _ -> total + 2
      | Load_edge _ | Read_edge _ | Remove_edge _ | Poll_edge _ | Retry_edge _
        -> total + 1)
    0 edges

let drain_tail ~profile ~seed ~length replay trace =
  let advance index replay trace event =
    let now = B.time replay.bridge + 1 in
    let trace =
      Printf.sprintf "tail%d:%d:%s" index now (show_input event) :: trace
    in
    let next =
      try step ~profile ~now replay event
      with Difference message ->
        fail "seed=%d prefix=%d tail=%d\n%s\n%s" seed length index message
          (String.concat "\n" (List.rev trace))
    in
    (next, trace)
  in
  let stopping, trace = advance 0 replay trace M.Shutdown in
  (* The edge ledger comes only from public commands and delivered callbacks.
     Workers cost two because their closure may require one final cleanup. *)
  let rec close index replay trace =
    match replay.edges with
    | [] ->
        if not (B.quiescent replay.bridge && C.quiescent replay.actual) then
          fail "Empty edge ledger did not leave both owners quiescent";
        true
    | edge :: _ ->
        let event =
          match edge with
          | Load_edge (id, Canceling) | Read_edge (id, Canceling) ->
              M.Request_canceled id
          | Remove_edge id -> M.Workspace_removed (id, Ok ())
          | Worker_edge (id, run, Child_stopping) ->
              M.Worker_finished (id, run, M.Canceled)
          | Load_edge (_, In_flight) | Read_edge (_, In_flight) ->
              fail "Shutdown left a request without a cancellation command"
          | Worker_edge (_, _, Child_running) ->
              fail "Shutdown left a worker without a stop command"
          | Poll_edge _ | Retry_edge _ ->
              fail "Shutdown left a timer registered"
        in
        let next, trace = advance index replay trace event in
        if edge_weight next.edges >= edge_weight replay.edges then
          fail "Post-close tail did not decrease its resource measure";
        close (index + 1) next trace
  in
  close 1 stopping trace

let pick random values =
  let index = Random.State.int random (max 1 (List.length values)) in
  List.find_map
    (fun (i, value) -> if i = index then Some value else None)
    (List.mapi (fun i value -> (i, value)) values)

let issue_ids =
  [
    "opaque-0";
    "opaque-1";
    "opaque-2";
    "opaque-3";
    "opaque-4";
    "opaque-5";
    "opaque-6";
    "opaque-7";
  ]

let sample_issues random =
  List.filter_map
    (fun id ->
      if Random.State.int random 4 = 0 then None
      else
        let index = bounded (String.sub id 7 1) in
        let state =
          match Random.State.int random 5 with
          | 0 -> "doing"
          | 1 -> "done"
          | 2 -> "paused"
          | 3 -> "closed"
          | _ -> "todo"
        in
        Some
          {
            M.id;
            identifier =
              (if index = 7 then "." else "CORE-" ^ string_of_int index);
            title = "Snapshot-" ^ string_of_int (Random.State.int random 4);
            state;
            dispatchable = Random.State.int random 5 <> 0;
            labels =
              List.filter
                (fun _ -> Random.State.bool random)
                [ "ready"; "reviewed"; "urgent" ];
            priority =
              (match Random.State.int random 6 with
              | 5 -> None
              | value -> Some value);
            created =
              (if Random.State.int random 3 = 0 then None
               else Some (Random.State.int random 60));
            key = (if index = 7 then M.Unsafe else M.Safe);
          })
    issue_ids

let actions history =
  let resources =
    List.filter_map
      (function
        | M.Load_workflow (q, _) -> Some (`Load q)
        | M.Read_tracker read -> Some (`Read read)
        | M.Start_worker start -> Some (`Worker start)
        | M.Remove_workspace (q, _) -> Some (`Remove q)
        | M.Arm_retry (id, token, due) -> Some (`Retry (id, token, due))
        | M.Arm_poll (q, due) -> Some (`Poll (q, due))
        | M.Cancel_request q -> Some (`Canceled q)
        | M.Stop_worker _ | M.Cancel_poll _ | M.Cancel_retry _ | M.Report _ ->
            None)
      history
  in
  `Refresh :: `Reload :: `Shutdown :: resources

let campaign seed length =
  let random = Random.State.make [| seed |] in
  let recent_window = 24 in
  let shutdown_after = 450 in
  let rec take limit = function
    | [] -> []
    | _ when limit = 0 -> []
    | head :: rest -> head :: take (limit - 1) rest
  in
  let rec loop index profile replay trace =
    if index = length then drain_tail ~profile ~seed ~length replay trace
    else
      let history =
        if Random.State.int random 4 = 0 then B.history replay.bridge
        else take recent_window (List.rev (B.history replay.bridge))
      in
      let selected =
        Option.value ~default:`Refresh (pick random (actions history))
      in
      let profile = Option.value ~default:profile (pick random profiles) in
      let elapsed =
        if Random.State.int random 8 <> 0 then Random.State.int random 50
        else
          Option.value ~default:0 (pick random [ 10000; 20000; 40000; 45000 ])
      in
      let now = B.time replay.bridge + elapsed in
      let success () = Random.State.int random 5 <> 0 in
      let event, now =
        match selected with
        | `Refresh -> (M.Refresh_requested, now)
        | `Reload -> (M.Workflow_changed, now)
        | `Shutdown ->
            ( (if index > shutdown_after then M.Shutdown else M.Refresh_requested),
              now )
        | `Load q ->
            ( M.Workflow_loaded
                (q, if success () then Ok (config profile) else Error ()),
              now )
        | `Read read ->
            let payload = sample_issues random in
            let payload =
              match read.M.selection with
              | M.States states ->
                  List.filter
                    (fun (issue : M.issue) -> List.mem issue.M.state states)
                    payload
              | M.Ids ids ->
                  List.filter
                    (fun (issue : M.issue) -> List.mem issue.M.id ids)
                    payload
            in
            ( M.Tracker_completed
                (read.M.id, if success () then Ok payload else Error ()),
              now )
        | `Worker worker ->
            let id =
              if Random.State.int random 8 = 0 then "crossed"
              else worker.M.issue.M.id
            in
            if Random.State.int random 3 = 0 then
              (M.Worker_started (id, worker.M.run), now)
            else
              let outcome =
                match Random.State.int random 6 with
                | 0 -> M.Failed
                | 1 -> M.Timed_out
                | 2 -> M.Stalled
                | 3 -> M.Canceled
                | 4 -> M.Cancel_error
                | _ -> M.Succeeded
              in
              (M.Worker_finished (id, worker.M.run, outcome), now)
        | `Remove q ->
            ( M.Workspace_removed (q, if success () then Ok () else Error ()),
              now )
        | `Retry (id, token, due) ->
            let id = if Random.State.int random 8 = 0 then "crossed" else id in
            ( M.Retry_due (id, token),
              max now (due + Random.State.int random 3 - 1) )
        | `Poll (q, due) -> (M.Poll_due q, max now due)
        | `Canceled q -> (M.Request_canceled q, now)
      in
      let trace =
        Printf.sprintf "%d:%d:%s" index now (show_input event) :: trace
      in
      let previous_history = List.length (B.history replay.bridge) in
      let next =
        try step ~profile ~now replay event
        with Difference message ->
          fail "seed=%d prefix=%d step=%d\n%s\n%s" seed length index message
            (String.concat "\n" (List.rev trace))
      in
      let effects =
        List.filteri
          (fun index _ -> index >= previous_history)
          (B.history next.bridge)
      in
      let trace =
        match effects with
        | [] -> trace
        | effects ->
            ("  -> " ^ String.concat "; " (List.map show_command effects))
            :: trace
      in
      loop (index + 1) profile next trace
  in
  loop 0 F.A (create F.A) []

let selected_load commands =
  match
    List.find_map
      (function
        | M.Load_workflow (id, _) -> Some id
        | M.Read_tracker _
        | M.Start_worker _
        | M.Stop_worker _
        | M.Remove_workspace _
        | M.Cancel_request _
        | M.Arm_poll _
        | M.Cancel_poll _
        | M.Arm_retry _
        | M.Cancel_retry _
        | M.Report _ -> None)
      commands
  with
  | Some id -> id
  | None -> fail "Readiness control did not start a loader"

let model_cancel_readiness () =
  let check prior =
    let initial, _ = M.create ~now:0 (config F.A) in
    let prior_state =
      match prior with
      | M.Ready -> initial
      | M.Invalid ->
          let loading, commands = M.step ~now:1 M.Workflow_changed initial in
          fst
            (M.step ~now:2
               (M.Workflow_loaded (selected_load commands, Error ()))
               loading)
      | M.Loading -> fail "Readiness control needs a completed prior validation"
    in
    let loading, commands = M.step ~now:3 M.Workflow_changed prior_state in
    let selected = selected_load commands in
    let stopping, _ = M.step ~now:4 M.Shutdown loading in
    let closed, _ = M.step ~now:5 (M.Request_canceled selected) stopping in
    let observed = M.project ~now:5 closed in
    if observed.M.readiness <> prior then
      fail "Closed selected loader did not restore %s:\n%s"
        (match prior with
        | M.Ready -> "Ready"
        | M.Invalid -> "Invalid"
        | M.Loading -> "Loading")
        (show_projection observed)
  in
  let errors =
    List.filter_map
      (fun prior ->
        try
          check prior;
          None
        with Difference message -> Some message)
      [ M.Ready; M.Invalid ]
  in
  match errors with
  | [] -> true
  | errors -> fail "%s" (String.concat "\n" errors)

type close_order = Candidate_first | Loader_first

let selected_read commands =
  match
    List.find_map
      (function
        | M.Read_tracker read -> Some read.M.id
        | M.Load_workflow _
        | M.Start_worker _
        | M.Stop_worker _
        | M.Remove_workspace _
        | M.Cancel_request _
        | M.Arm_poll _
        | M.Cancel_poll _
        | M.Arm_retry _
        | M.Cancel_retry _
        | M.Report _ -> None)
      commands
  with
  | Some id -> id
  | None -> fail "Invalid replacement control did not start a read"

let model_step ~now input (state, edges) =
  let state, commands = M.step ~now input state in
  let edges =
    List.fold_left register_edge (close_edges now input edges) commands
  in
  ((state, edges), commands)

let live_poll edges =
  match
    List.filter_map
      (function
        | Poll_edge (token, due) -> Some (token, due)
        | Load_edge _
        | Read_edge _
        | Remove_edge _
        | Worker_edge _
        | Retry_edge _ -> None)
      edges
  with
  | [ poll ] -> poll
  | [] | _ :: _ :: _ -> fail "Exactly one live cadence timer is required"

let preflight_effect file = function
  | M.Load_workflow (_, selected) -> String.equal file selected
  | M.Read_tracker _
  | M.Start_worker _
  | M.Stop_worker _
  | M.Remove_workspace _
  | M.Cancel_request _
  | M.Arm_poll _
  | M.Cancel_poll _
  | M.Arm_retry _
  | M.Cancel_retry _
  | M.Report _ -> false

let reconcile_effect binding selection = function
  | M.Read_tracker read ->
      read.M.binding = binding && read.M.selection = selection
  | M.Load_workflow _
  | M.Start_worker _
  | M.Stop_worker _
  | M.Remove_workspace _
  | M.Cancel_request _
  | M.Arm_poll _
  | M.Cancel_poll _
  | M.Arm_retry _
  | M.Cancel_retry _
  | M.Report _ -> false

let model_invalid_reload () =
  let check order =
    let initial, commands = M.create ~now:0 (config F.A) in
    let startup = selected_read commands in
    let initial = (initial, List.fold_left register_edge [] commands) in
    let serving, _ =
      model_step ~now:1 (M.Tracker_completed (startup, Ok [])) initial
    in
    let retained = live_poll (snd serving) in
    let checking, commands = model_step ~now:2 M.Refresh_requested serving in
    if
      commands
      <> [ M.Load_workflow (selected_load commands, (config F.A).M.file) ]
      || live_poll (snd checking) <> retained
    then fail "Explicit refresh must retain its one cadence timer";
    let fetching, commands =
      model_step ~now:3
        (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
        checking
    in
    let candidate = selected_read commands in
    let canceled, commands = model_step ~now:4 M.Workflow_changed fetching in
    let loader = selected_load commands in
    let first, second =
      match order with
      | Candidate_first ->
          (M.Request_canceled candidate, M.Workflow_loaded (loader, Error ()))
      | Loader_first ->
          (M.Workflow_loaded (loader, Error ()), M.Request_canceled candidate)
    in
    let interim, first_commands = model_step ~now:5 first canceled in
    if
      live_poll (snd interim) <> retained
      || (M.project ~now:5 (fst interim)).M.cycle <> M.Busy
    then
      fail
        "Half-closed invalid replacement must retain cadence and read custody";
    let ticked, tick_commands =
      model_step ~now:5 (M.Poll_due (fst retained)) interim
    in
    let next, due = live_poll (snd ticked) in
    if
      tick_commands <> [ M.Arm_poll (next, due) ]
      || next = fst retained
      || due <> 5 + (config F.A).M.poll_ms
    then
      fail "Busy invalid replacement must rearm once without overlapping reads";
    let repeated, repeated_commands =
      model_step ~now:5 (M.Poll_due (fst retained)) ticked
    in
    if repeated_commands <> [] || live_poll (snd repeated) <> (next, due) then
      fail "Retired cadence token cannot reserve a second timer";
    let closed, last_commands = model_step ~now:6 second repeated in
    let effects = first_commands @ last_commands in
    if
      effects <> [ M.Report M.Config_failure ]
      || snd closed <> [ Poll_edge (next, due) ]
      || (M.project ~now:6 (fst closed)).M.readiness <> M.Invalid
      || (M.project ~now:6 (fst closed)).M.cycle <> M.Idle
    then
      fail
        "Invalid candidate replacement (%s) must close custody and retain one \
         poll:\n\
         %s"
        (match order with
        | Candidate_first -> "candidate-first"
        | Loader_first -> "loader-first")
        (String.concat "\n" (List.map show_command effects));
    let next_tick, commands = model_step ~now:11 (M.Poll_due next) closed in
    let timer, next_due = live_poll (snd next_tick) in
    let paced =
      match commands with
      | [ poll; preflight ] ->
          poll = M.Arm_poll (timer, next_due)
          && preflight_effect (config F.A).M.file preflight
      | [] | [ _ ] | _ :: _ :: _ :: _ -> false
    in
    if (not paced) || next_due <> 11 + (config F.A).M.poll_ms then
      fail "Invalid readiness must retain the accepted cadence before preflight"
  in
  let errors =
    List.filter_map
      (fun order ->
        try
          check order;
          None
        with Difference message -> Some message)
      [ Candidate_first; Loader_first ]
  in
  match errors with
  | [] -> true
  | errors -> fail "%s" (String.concat "\n" errors)

type bootstrap_order = Cleanup_first | Superseded_first

let selected_removal commands =
  match
    List.find_map
      (function
        | M.Remove_workspace (id, _) -> Some id
        | M.Load_workflow _
        | M.Read_tracker _
        | M.Start_worker _
        | M.Stop_worker _
        | M.Cancel_request _
        | M.Arm_poll _
        | M.Cancel_poll _
        | M.Arm_retry _
        | M.Cancel_retry _
        | M.Report _ -> None)
      commands
  with
  | Some id -> id
  | None -> fail "Bootstrap control did not reserve cleanup"

let model_bootstrap_custody () =
  let check order =
    let terminal =
      {
        M.id = "bootstrap-issue";
        M.identifier = "BOOT-1";
        M.title = "Terminal bootstrap fixture";
        M.state = "done";
        M.dispatchable = true;
        M.labels = [];
        M.priority = None;
        M.created = None;
        M.key = M.Safe;
      }
    in
    let initial, commands = M.create ~now:0 (config F.A) in
    let removing, commands =
      M.step ~now:1
        (M.Tracker_completed (selected_read commands, Ok [ terminal ]))
        initial
    in
    let cleanup = selected_removal commands in
    let loading, commands = M.step ~now:2 M.Workflow_changed removing in
    let superseded = selected_load commands in
    let replacing, commands = M.step ~now:3 M.Workflow_changed loading in
    let settled, _ =
      M.step ~now:4
        (M.Workflow_loaded (selected_load commands, Ok (config F.Tight)))
        replacing
    in
    let first, second =
      match order with
      | Cleanup_first ->
          (M.Workspace_removed (cleanup, Ok ()), M.Request_canceled superseded)
      | Superseded_first ->
          (M.Request_canceled superseded, M.Workspace_removed (cleanup, Ok ()))
    in
    let interim, early = M.step ~now:5 first settled in
    if early <> [] then
      fail "Bootstrap (%s) advanced before all job closures:\n%s"
        (match order with
        | Cleanup_first -> "cleanup-first"
        | Superseded_first -> "loader-first")
        (String.concat "\n" (List.map show_command early));
    let closed, effects = M.step ~now:6 second interim in
    let startup = selected_read effects in
    let current = config F.Tight in
    let terminal_read =
      List.exists
        (function
          | M.Read_tracker read ->
              read.M.binding = current.M.binding
              && read.M.terminal = current.M.terminal
              && read.M.selection = M.States current.M.terminal
          | M.Load_workflow _
          | M.Start_worker _
          | M.Stop_worker _
          | M.Remove_workspace _
          | M.Cancel_request _
          | M.Arm_poll _
          | M.Cancel_poll _
          | M.Arm_retry _
          | M.Cancel_retry _
          | M.Report _ -> false)
        effects
    in
    if List.length effects <> 1 || not terminal_read then
      fail "Bootstrap closure must reserve exactly one fresh terminal read";
    let serving, _ =
      M.step ~now:7 (M.Tracker_completed (startup, Ok [])) closed
    in
    if (M.project ~now:7 serving).M.mode <> M.Serving then
      fail "Fully closed bootstrap did not progress to Serving"
  in
  let errors =
    List.filter_map
      (fun order ->
        try
          check order;
          None
        with Difference message -> Some message)
      [ Cleanup_first; Superseded_first ]
  in
  match errors with
  | [] -> true
  | errors -> fail "%s" (String.concat "\n" errors)

let model_bootstrap_poll () =
  let initial, commands = M.create ~now:0 (config F.A) in
  let startup = selected_read commands in
  let loading, commands = M.step ~now:1 M.Workflow_changed initial in
  let loader = selected_load commands in
  let waiting, early =
    M.step ~now:2 (M.Tracker_completed (startup, Ok [])) loading
  in
  if early <> [] then fail "Bootstrap advanced before its latest loader closed";
  let closed, effects =
    M.step ~now:3 (M.Workflow_loaded (loader, Ok (config F.A))) waiting
  in
  let one_poll =
    List.length effects = 1
    && List.exists
         (function
           | M.Arm_poll (_, due) -> due = 3
           | M.Load_workflow _
           | M.Read_tracker _
           | M.Start_worker _
           | M.Stop_worker _
           | M.Remove_workspace _
           | M.Cancel_request _
           | M.Cancel_poll _
           | M.Arm_retry _
           | M.Cancel_retry _
           | M.Report _ -> false)
         effects
  in
  if (not one_poll) || (M.project ~now:3 closed).M.mode <> M.Serving then
    fail "Final bootstrap loader must reserve one initial poll:\n%s"
      (String.concat "\n" (List.map show_command effects));
  true

type validation_order = Old_load_first | Invalid_load_first

let model_borrowed_preflight () =
  let check order =
    let current =
      {
        M.id = "borrowed-worker";
        M.identifier = "BORROW-1";
        M.title = "Borrowed validation fixture";
        M.state = "doing";
        M.dispatchable = true;
        M.labels = [];
        M.priority = None;
        M.created = None;
        M.key = M.Safe;
      }
    in
    let initial, commands = M.create ~now:0 (config F.A) in
    let initial = (initial, List.fold_left register_edge [] commands) in
    let serving, _ =
      model_step ~now:1
        (M.Tracker_completed (selected_read commands, Ok []))
        initial
    in
    let retained = live_poll (snd serving) in
    let checking, commands = model_step ~now:2 M.Refresh_requested serving in
    let fetching, commands =
      model_step ~now:3
        (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
        checking
    in
    let starting, commands =
      model_step ~now:4
        (M.Tracker_completed (selected_read commands, Ok [ current ]))
        fetching
    in
    let worker =
      match
        List.find_map
          (function
            | M.Start_worker worker -> Some worker
            | M.Load_workflow _
            | M.Read_tracker _
            | M.Stop_worker _
            | M.Remove_workspace _
            | M.Cancel_request _
            | M.Arm_poll _
            | M.Cancel_poll _
            | M.Arm_retry _
            | M.Cancel_retry _
            | M.Report _ -> None)
          commands
      with
      | Some worker -> worker
      | None -> fail "Borrowed validation control did not start its worker"
    in
    let active, _ =
      model_step ~now:5 (M.Worker_started (current.M.id, worker.M.run)) starting
    in
    let reconciling, commands = model_step ~now:6 M.Refresh_requested active in
    let reconcile = selected_read commands in
    let loading, commands = model_step ~now:7 M.Workflow_changed reconciling in
    let borrowed = selected_load commands in
    let validating, _ =
      model_step ~now:8
        (M.Tracker_completed (reconcile, Ok [ current ]))
        loading
    in
    let replacing, commands = model_step ~now:9 M.Workflow_changed validating in
    let latest = selected_load commands in
    let first, second, expected_early =
      match order with
      | Old_load_first ->
          (M.Request_canceled borrowed, M.Workflow_loaded (latest, Error ()), [])
      | Invalid_load_first ->
          ( M.Workflow_loaded (latest, Error ()),
            M.Request_canceled borrowed,
            [ M.Report M.Config_failure ] )
    in
    let interim, early = model_step ~now:10 first replacing in
    if early <> expected_early then
      fail "Borrowed preflight (%s) advanced before both loaders closed:\n%s"
        (match order with
        | Old_load_first -> "old-load-first"
        | Invalid_load_first -> "invalid-load-first")
        (String.concat "\n" (List.map show_command early));
    if
      live_poll (snd interim) <> retained
      || (M.project ~now:10 (fst interim)).M.cycle <> M.Busy
    then
      fail
        "Unclosed borrowed preflight must retain cadence and its remaining \
         loader";
    let ticked, commands =
      model_step ~now:10 (M.Poll_due (fst retained)) interim
    in
    let next, due = live_poll (snd ticked) in
    if
      commands <> [ M.Arm_poll (next, due) ]
      || next = fst retained
      || due <> 10 + (config F.A).M.poll_ms
    then
      fail "Busy borrowed preflight must rearm once without overlapping reads";
    let closed, effects = model_step ~now:200 second ticked in
    let surviving =
      [
        Worker_edge (current.M.id, worker.M.run, Child_running);
        Poll_edge (next, due);
      ]
    in
    if
      early @ effects <> [ M.Report M.Config_failure ]
      || snd closed <> surviving
      || (M.project ~now:200 (fst closed)).M.readiness <> M.Invalid
      || (M.project ~now:200 (fst closed)).M.cycle <> M.Idle
    then
      fail
        "Closed borrowed preflight must retain one worker and one cadence timer";
    let next_tick, commands = model_step ~now:200 (M.Poll_due next) closed in
    let timer, next_due = live_poll (snd next_tick) in
    let paced =
      match commands with
      | [ poll; reconcile ] ->
          poll = M.Arm_poll (timer, next_due)
          && reconcile_effect (config F.A).M.binding (M.Ids [ current.M.id ])
               reconcile
      | [] | [ _ ] | _ :: _ :: _ :: _ -> false
    in
    if (not paced) || next_due <> 200 + (config F.A).M.poll_ms then
      fail
        "Accepted cadence must reconcile the original worker before preflight"
  in
  let errors =
    List.filter_map
      (fun order ->
        try
          check order;
          None
        with Difference message -> Some message)
      [ Old_load_first; Invalid_load_first ]
  in
  match errors with
  | [] -> true
  | errors -> fail "%s" (String.concat "\n" errors)

let model_attempts () =
  let initial, commands = M.create ~now:0 (config F.A) in
  let serving, _ =
    M.step ~now:1 (M.Tracker_completed (selected_read commands, Ok [])) initial
  in
  let checking, commands = M.step ~now:2 M.Refresh_requested serving in
  let fetching, commands =
    M.step ~now:3
      (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
      checking
  in
  let unsafe =
    {
      M.id = "retry-fixture";
      M.identifier = ".";
      M.title = "Rejected reference fixture";
      M.state = "doing";
      M.dispatchable = true;
      M.labels = [];
      M.priority = None;
      M.created = None;
      M.key = M.Unsafe;
    }
  in
  let waiting, _ =
    M.step ~now:4
      (M.Tracker_completed (selected_read commands, Ok [ unsafe ]))
      fetching
  in
  let last_attempt = 17 in
  let rec advance expected now state =
    let queued =
      match (M.project ~now state).M.owners with
      | [ M.Retry queued ] -> queued
      | [] | M.Worker _ :: _ | M.Cleaning _ :: _ | M.Retry _ :: _ ->
          fail "Retry history lost its sole queued owner at attempt %d" expected
    in
    if queued.M.attempt <> expected then
      fail "Retry history expected attempt %d, observed %d" expected
        queued.M.attempt;
    (match M.invariant state with
    | Ok () -> ()
    | Error message ->
        fail "Valid retry history rejected at attempt %d: %s" expected message);
    if expected = last_attempt then true
    else
      let due =
        match queued.M.phase with
        | M.Waiting due -> due
        | M.Refreshing | M.Parked ->
            fail "Retry history expected a timer at attempt %d" expected
      in
      let refreshing, commands =
        M.step ~now:due (M.Retry_due (unsafe.M.id, queued.M.retry)) state
      in
      let next, _ =
        M.step ~now:(due + 1)
          (M.Tracker_completed (selected_read commands, Error ()))
          refreshing
      in
      advance (expected + 1) (due + 1) next
  in
  advance 1 4 waiting

let model_retry_close () =
  let make id identifier : M.issue =
    {
      M.id;
      M.identifier;
      M.title = "Closed retry fixture";
      M.state = "doing";
      M.dispatchable = true;
      M.labels = [];
      M.priority = None;
      M.created = None;
      M.key = M.Safe;
    }
  in
  let first_issue = make "retry-a" "RETRY-1" in
  let second_issue = make "retry-b" "RETRY-2" in
  let initial, commands = M.create ~now:0 (config F.A) in
  let serving, _ =
    M.step ~now:1 (M.Tracker_completed (selected_read commands, Ok [])) initial
  in
  let checking, commands = M.step ~now:2 M.Refresh_requested serving in
  let fetching, commands =
    M.step ~now:3
      (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
      checking
  in
  let started, commands =
    M.step ~now:4
      (M.Tracker_completed
         (selected_read commands, Ok [ first_issue; second_issue ]))
      fetching
  in
  let workers =
    List.filter_map
      (function
        | M.Start_worker worker -> Some worker
        | M.Load_workflow _
        | M.Read_tracker _
        | M.Stop_worker _
        | M.Remove_workspace _
        | M.Cancel_request _
        | M.Arm_poll _
        | M.Cancel_poll _
        | M.Arm_retry _
        | M.Cancel_retry _
        | M.Report _ -> None)
      commands
  in
  let first, second =
    match workers with
    | [ first; second ] -> (first, second)
    | [] | [ _ ] | _ :: _ :: _ :: _ ->
        fail "Retry close control did not start both workers"
  in
  let queued, _ =
    M.step ~now:5
      (M.Worker_finished (first_issue.M.id, first.M.run, M.Succeeded))
      started
  in
  let queued, _ =
    M.step ~now:6
      (M.Worker_finished (second_issue.M.id, second.M.run, M.Succeeded))
      queued
  in
  let queued_retry id now state =
    match
      List.find_map
        (function
          | M.Retry retry when retry.M.issue.M.id = id -> Some retry
          | M.Retry _ | M.Worker _ | M.Cleaning _ -> None)
        (M.project ~now state).M.owners
    with
    | Some retry -> retry
    | None -> fail "Retry close control lost %s" id
  in
  let first = queued_retry first_issue.M.id 6 queued in
  let second = queued_retry second_issue.M.id 6 queued in
  let due = function
    | M.Waiting due -> due
    | M.Refreshing | M.Parked -> fail "Retry close control expected timers"
  in
  let first_due = due first.M.phase in
  let second_due = due second.M.phase in
  let refreshing, commands =
    M.step ~now:first_due (M.Retry_due (first_issue.M.id, first.M.retry)) queued
  in
  let superseded = selected_read commands in
  let loading, commands = M.step ~now:first_due M.Workflow_changed refreshing in
  let repaired, _ =
    M.step ~now:first_due
      (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
      loading
  in
  let now = second_due + 100 in
  let closed, effects = M.step ~now (M.Request_canceled superseded) repaired in
  let only_first =
    match effects with
    | [ command ] -> (
        match command with
        | M.Read_tracker read -> read.M.selection = M.Ids [ first_issue.M.id ]
        | M.Load_workflow _
        | M.Start_worker _
        | M.Stop_worker _
        | M.Remove_workspace _
        | M.Cancel_request _
        | M.Arm_poll _
        | M.Cancel_poll _
        | M.Arm_retry _
        | M.Cancel_retry _
        | M.Report _ -> false)
    | [] | _ :: _ :: _ -> false
  in
  let observed_second = queued_retry second_issue.M.id now closed in
  let second_waiting =
    match observed_second.M.phase with
    | M.Waiting due -> due = second_due
    | M.Refreshing | M.Parked -> false
  in
  if (not only_first) || not second_waiting then
    fail "Closing retry A must leave overdue retry B waiting:\n%s\n%s"
      (String.concat "\n" (List.map show_command effects))
      (show_projection (M.project ~now closed));
  true

let properties =
  let open QCheck2 in
  let gen =
    Gen.map2
      (fun seed length -> (seed, length))
      (Gen.no_shrink (Gen.int_range 0 1_000_000))
      (Gen.set_shrink (Shrink.int_towards 0) (Gen.int_range 500 600))
  in
  [
    Test.make ~name:"event core matches independent model after every step"
      ~count:200
      ~print:(fun (seed, length) ->
        Printf.sprintf "seed=%d prefix=%d" seed length)
      gen
      (fun (seed, length) ->
        try campaign seed length
        with Difference message -> Test.fail_report message);
    Test.make ~name:"closed selected loader restores prior validation" ~count:1
      (Gen.return ()) (fun () ->
        try model_cancel_readiness ()
        with Difference message -> Test.fail_report message);
    Test.make ~name:"invalid candidate replacement finishes once after close"
      ~count:1 (Gen.return ()) (fun () ->
        try model_invalid_reload ()
        with Difference message -> Test.fail_report message);
    Test.make ~name:"bootstrap joins superseded loader and cleanup custody"
      ~count:1 (Gen.return ()) (fun () ->
        try model_bootstrap_custody ()
        with Difference message -> Test.fail_report message);
    Test.make ~name:"final bootstrap loader reserves one initial poll" ~count:1
      (Gen.return ()) (fun () ->
        try model_bootstrap_poll ()
        with Difference message -> Test.fail_report message);
    Test.make ~name:"borrowed preflight retains both loader close obligations"
      ~count:1 (Gen.return ()) (fun () ->
        try model_borrowed_preflight ()
        with Difference message -> Test.fail_report message);
    Test.make ~name:"valid retry history can exceed sixteen attempts" ~count:1
      (Gen.return ()) (fun () ->
        try model_attempts ()
        with Difference message -> Test.fail_report message);
    Test.make ~name:"matched retry closure never wakes another overdue timer"
      ~count:1 (Gen.return ()) (fun () ->
        try model_retry_close ()
        with Difference message -> Test.fail_report message);
  ]
