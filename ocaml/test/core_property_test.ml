module F = Core_fixture
module C = F.Core
module M = Core_model
module T = Tracker_registry.Contract

exception Difference of string

let fail fmt = Printf.ksprintf (fun message -> raise (Difference message)) fmt

let bounded text =
  match int_of_string_opt text with
  | Some value -> value
  | None -> fail "Model fixture integer outside bounded domain: %s" text

let natural value = bounded (Count.decimal value)
let positive value = natural (Positive_count.count value)
let ticks instant = natural (Clock.Pure.nanoseconds instant) / 1_000_000
let duration seconds = natural (Seconds.nanoseconds seconds) / 1_000_000
let issue_id value = Issue_id.text value

let profiles =
  [
    F.A;
    F.B;
    F.Declining;
    F.Other_scope;
    F.Tight;
    F.New_policy;
    F.Required;
    F.Growing_retry;
  ]

let creation_text second = Printf.sprintf "2026-01-01T00:00:%02dZ" second

let creation_values =
  List.init 60 (fun second ->
      (Printf.sprintf "2026-01-01T00:00:%02d.000000000000Z" second, second))

let created value =
  Option.map
    (fun timestamp ->
      let text = Utc.rfc3339 timestamp in
      match List.assoc_opt text creation_values with
      | Some second -> second
      | None -> fail "Unexpected fixture creation timestamp: %s" text)
    (Issue.created_at value)

let config profile : M.config =
  let binding, scope, root, launch, plan_mode =
    match profile with
    | F.A | F.Tight | F.New_policy | F.Required | F.Growing_retry ->
        (1, 1, 1, 1, M.Accept)
    | F.B -> (2, 1, 2, 2, M.Accept)
    | F.Declining -> (3, 1, 3, 3, M.Decline)
    | F.Other_scope -> (4, 2, 4, 4, M.Accept)
  in
  {
    M.binding;
    M.scope;
    M.root;
    M.launch;
    M.file = "/fixture/core/WORKFLOW.md";
    M.active = [ "doing"; "todo" ];
    M.terminal =
      (match profile with
      | F.New_policy -> [ "closed"; "done" ]
      | F.A
      | F.B
      | F.Declining
      | F.Other_scope
      | F.Tight
      | F.Required
      | F.Growing_retry -> [ "done" ]);
    M.required =
      (match profile with
      | F.Required -> [ "ready"; "reviewed" ]
      | F.A
      | F.B
      | F.Declining
      | F.Other_scope
      | F.Tight
      | F.New_policy
      | F.Growing_retry -> []);
    M.global_cap =
      (match profile with
      | F.Tight -> 1
      | F.A
      | F.B
      | F.Declining
      | F.Other_scope
      | F.New_policy
      | F.Required
      | F.Growing_retry -> 2);
    M.state_caps = [ ("doing", 2); ("todo", 1) ];
    M.poll_ms =
      (match profile with
      | F.New_policy -> 7
      | F.A
      | F.B
      | F.Declining
      | F.Other_scope
      | F.Tight
      | F.Required
      | F.Growing_retry -> 5);
    M.retry_cap_ms =
      (match profile with
      | F.Growing_retry -> 45000
      | F.A
      | F.B
      | F.Declining
      | F.Other_scope
      | F.Tight
      | F.New_policy
      | F.Required -> 40);
    M.plan_mode;
  }

let issue value : M.issue =
  let identifier = Issue_identifier.text (Issue.identifier value) in
  {
    M.id = issue_id (Issue.id value);
    M.identifier;
    M.title = Issue.title value;
    M.state = Issue.state_key value;
    M.dispatchable = Issue.routing value = Issue.Dispatchable;
    M.labels = Issue.labels value;
    M.priority = Issue.priority value;
    M.created = created value;
    M.key = (if String.equal identifier "." then M.Unsafe else M.Safe);
  }

let actual_issue (value : M.issue) =
  F.issue ~state:value.M.state ~title:value.M.title
    ~routing:
      (if value.M.dispatchable then Issue.Dispatchable else Issue.Unroutable)
    ~labels:value.M.labels ?priority:value.M.priority ~id:value.M.id
    ?created_at:(Option.map creation_text value.M.created)
    ~identifier:value.M.identifier ()

type tokens = {
  requests : (M.request * Request_id.t) list;
  runs : (M.run * Run_id.t) list;
  retries : (M.retry_id * Retry_id.t) list;
}

let empty_tokens = { requests = []; runs = []; retries = [] }

let bind kind equal model actual bindings =
  match List.assoc_opt model bindings with
  | Some previous when equal previous actual -> bindings
  | Some _ -> fail "%s token was rebound" kind
  | None ->
      if List.exists (fun (_, previous) -> equal previous actual) bindings then
        fail "%s token was reused" kind;
      (model, actual) :: bindings

let request tokens model =
  match List.assoc_opt model tokens.requests with
  | Some actual -> actual
  | None -> fail "Missing request producer"

let run tokens model =
  match List.assoc_opt model tokens.runs with
  | Some actual -> actual
  | None -> fail "Missing run producer"

let retry tokens model =
  match List.assoc_opt model tokens.retries with
  | Some actual -> actual
  | None -> fail "Missing retry producer"

let model_token kind equal actual bindings =
  match List.find_opt (fun (_, concrete) -> equal concrete actual) bindings with
  | Some (model, _) -> model
  | None -> fail "Unexpected concrete %s token" kind

let model_request tokens actual =
  model_token "request" Request_id.equal actual tokens.requests

let model_run tokens actual = model_token "run" Run_id.equal actual tokens.runs

let model_retry tokens actual =
  model_token "retry" Retry_id.equal actual tokens.retries

let pair tokens expected actual =
  let q model concrete =
    {
      tokens with
      requests = bind "request" Request_id.equal model concrete tokens.requests;
    }
  in
  match (expected, actual) with
  | M.Load_workflow (id, _), C.Load_workflow { id = concrete; _ }
  | ( M.Remove_workspace (id, _),
      C.Remove_workspace { F.Workspace.request_id = concrete; _ } )
  | M.Arm_poll (id, _), C.Arm_poll (concrete, _) -> q id concrete
  | ( M.Read_tracker { M.id; _ },
      C.Read_tracker (T.States { id = concrete; _ } | T.Ids { id = concrete; _ })
    ) -> q id concrete
  | M.Start_worker { M.run; _ }, C.Start_worker value ->
      {
        tokens with
        runs = bind "run" Run_id.equal run (F.Agent.run_id value) tokens.runs;
      }
  | M.Arm_retry (_, id, _), C.Arm_retry (_, concrete, _) ->
      {
        tokens with
        retries = bind "retry" Retry_id.equal id concrete tokens.retries;
      }
  | ( ( M.Load_workflow _
      | M.Remove_workspace _
      | M.Arm_poll _
      | M.Read_tracker _
      | M.Start_worker _
      | M.Arm_retry _
      | M.Stop_worker _
      | M.Cancel_request _
      | M.Cancel_poll _
      | M.Cancel_retry _
      | M.Report _ ),
      ( C.Load_workflow _ | C.Remove_workspace _ | C.Arm_poll _
      | C.Read_tracker (T.States _ | T.Ids _)
      | C.Start_worker _
      | C.Arm_retry _
      | C.Stop_worker _
      | C.Cancel_request _
      | C.Cancel_poll _
      | C.Cancel_retry _
      | C.Report _ ) ) -> tokens

let scope value =
  let matches profile =
    Tracker_scope.equal value (T.scope (F.Config.tracker (F.config profile)))
  in
  if matches F.A then 1
  else if matches F.Other_scope then 2
  else fail "Unknown scope authority"

let root value =
  match
    Absolute_path.display (Workspace_settings.root (F.Workspace.settings value))
  with
  | "/fixture/root-a" -> 1
  | "/fixture/root-b" -> 2
  | "/fixture/root-declining" -> 3
  | "/fixture/root-other" -> 4
  | unknown -> fail "Unexpected root authority: %s" unknown

let reference value : M.reference =
  {
    M.scope = scope (F.Workspace.scope value);
    M.id = issue_id (F.Workspace.issue_id value);
    M.identifier = Issue_identifier.text (F.Workspace.identifier value);
    M.root = root value;
  }

let launch value =
  let tag, key =
    match F.Agent.prompt_source value with
    | "a" -> ("a", 1)
    | "b" -> ("b", 2)
    | "decline" -> ("declining", 3)
    | "other" -> ("other", 4)
    | unknown -> fail "Unexpected frozen prompt: %s" unknown
  in
  let equal expected actual =
    if not (String.equal expected actual) then
      fail "Frozen launch differs: expected %s, got %s" expected actual
  in
  equal
    ("agent-" ^ tag ^ " app-server")
    (Agent_settings.command (F.Agent.agent value));
  equal "/fixture/core/WORKFLOW.md"
    (Workflow_path.display (F.Agent.prompt_file value));
  let env =
    Environment.bindings (F.Workspace.environment (F.Agent.workspace value))
  in
  let expected =
    [ ("HOME", "/fixture/home-" ^ tag); ("PATH", "/fixture/bin-" ^ tag) ]
  in
  if List.sort Stdlib.compare env <> expected then
    fail "Frozen child environment differs";
  key

let attempt = function
  | Template.First -> None
  | Template.Follow_up value -> Some (positive value)

let cancel = function
  | Agent_runner.Reconciliation -> M.Reconciliation
  | Agent_runner.Scope_change -> M.Scope_change
  | Agent_runner.Host_shutdown -> M.Host_shutdown

let command tokens = function
  | C.Load_workflow { id; file } ->
      M.Load_workflow (model_request tokens id, Workflow_path.display file)
  | C.Read_tracker read ->
      let id, binding, policy, selection =
        match read with
        | T.States { id; binding; policy; names } ->
            (id, binding, policy, M.States names)
        | T.Ids { id; binding; policy; ids } ->
            ( id,
              binding,
              policy,
              M.Ids (List.map issue_id (Issue_id.Set.elements ids)) )
      in
      M.Read_tracker
        {
          M.id = model_request tokens id;
          M.binding = (config (F.binding_profile binding)).M.binding;
          M.terminal = Tracker_read_policy.terminal policy;
          M.selection;
        }
  | C.Start_worker value ->
      M.Start_worker
        {
          M.issue = issue (F.Agent.issue value);
          M.run = model_run tokens (F.Agent.run_id value);
          M.reference = reference (F.Agent.workspace value);
          M.launch = launch value;
          M.attempt = attempt (F.Agent.attempt value);
        }
  | C.Stop_worker (id, token, reason) ->
      M.Stop_worker (issue_id id, model_run tokens token, cancel reason)
  | C.Remove_workspace value ->
      M.Remove_workspace
        ( model_request tokens value.F.Workspace.request_id,
          reference value.F.Workspace.workspace )
  | C.Cancel_request id -> M.Cancel_request (model_request tokens id)
  | C.Arm_poll (id, due) -> M.Arm_poll (model_request tokens id, ticks due)
  | C.Cancel_poll id -> M.Cancel_poll (model_request tokens id)
  | C.Arm_retry (id, token, due) ->
      M.Arm_retry (issue_id id, model_retry tokens token, ticks due)
  | C.Cancel_retry (id, token) ->
      M.Cancel_retry (issue_id id, model_retry tokens token)
  | C.Report fault ->
      M.Report
        (match fault with
        | C.Config_failure _ -> M.Config_failure
        | C.Tracker_failure _ -> M.Tracker_failure
        | C.Issue_tracker_failure (current, _) ->
            M.Issue_tracker_failure (issue current)
        | C.Planning_failure (current, _) -> M.Planning_failure (issue current)
        | C.Cleanup_failure (current, _) -> M.Cleanup_failure (issue current)
        | C.Lifecycle_failure (current, _) ->
            M.Lifecycle_failure (issue current)
        | C.Attempt_failure (current, _) -> M.Attempt_failure (issue current)
        | C.Attempt_timeout (current, _) -> M.Attempt_timeout (issue current)
        | C.Attempt_stalled current -> M.Attempt_stalled (issue current)
        | C.Attempt_cancel_error (current, _) ->
            M.Attempt_cancel_error (issue current))

let worker_phase = function
  | C.Starting -> M.Starting
  | C.Active -> M.Active
  | C.Stopping -> M.Stopping

let retry_phase = function
  | C.Waiting due -> M.Waiting (ticks due)
  | C.Refreshing -> M.Refreshing
  | C.Parked -> M.Parked

let owner tokens = function
  | C.Worker value ->
      M.Worker
        {
          M.issue = issue value.C.issue;
          M.run = model_run tokens value.C.run;
          M.phase = worker_phase value.C.phase;
          M.attempt = attempt value.C.attempt;
          M.seconds_ms = duration value.C.seconds_running;
        }
  | C.Retry value ->
      M.Retry
        {
          M.issue = issue value.C.issue;
          M.retry = model_retry tokens value.C.retry;
          M.phase = retry_phase value.C.phase;
          M.attempt = positive value.C.attempt;
        }
  | C.Cleaning value -> M.Cleaning (issue value)

let projection tokens (value : C.projection) : M.projection =
  {
    M.mode =
      (match value.C.mode with
      | C.Startup -> M.Startup
      | C.Serving -> M.Serving
      | C.Draining_scope -> M.Draining_scope
      | C.Shutting_down -> M.Shutting_down);
    M.readiness =
      (match value.C.readiness with
      | C.Ready -> M.Ready
      | C.Loading -> M.Loading
      | C.Invalid -> M.Invalid);
    M.owners = List.map (owner tokens) value.C.owners;
    M.running = value.C.running;
    M.available_slots = value.C.available_slots;
    M.total_runtime_ms = duration value.C.total_runtime;
  }

let show_request (M.Request value) = string_of_int value
let show_run (M.Run value) = string_of_int value
let show_retry (M.Retry_id value) = string_of_int value

let show_int = function
  | None -> "null"
  | Some value -> string_of_int value

let show_issue (value : M.issue) =
  Printf.sprintf
    "{id=%S identifier=%S title=%S state=%S dispatchable=%b labels=[%s] \
     priority=%s created=%s key=%s}"
    value.M.id value.M.identifier value.M.title value.M.state
    value.M.dispatchable
    (String.concat ";" (List.map (Printf.sprintf "%S") value.M.labels))
    (show_int value.M.priority)
    (show_int value.M.created)
    (match value.M.key with
    | M.Safe -> "safe"
    | M.Unsafe -> "unsafe")

let show_ref (value : M.reference) =
  Printf.sprintf "{scope=%d id=%S identifier=%S root=%d}" value.M.scope
    value.M.id value.M.identifier value.M.root

let show_cancel = function
  | M.Reconciliation -> "reconciliation"
  | M.Scope_change -> "scope-change"
  | M.Host_shutdown -> "shutdown"

let show_fault = function
  | M.Config_failure -> "config"
  | M.Tracker_failure -> "tracker"
  | M.Issue_tracker_failure current ->
      "issue-tracker(" ^ show_issue current ^ ")"
  | M.Planning_failure current -> "planning(" ^ show_issue current ^ ")"
  | M.Cleanup_failure current -> "cleanup(" ^ show_issue current ^ ")"
  | M.Lifecycle_failure current -> "lifecycle(" ^ show_issue current ^ ")"
  | M.Attempt_failure current -> "attempt-failure(" ^ show_issue current ^ ")"
  | M.Attempt_timeout current -> "attempt-timeout(" ^ show_issue current ^ ")"
  | M.Attempt_stalled current -> "attempt-stalled(" ^ show_issue current ^ ")"
  | M.Attempt_cancel_error current ->
      "attempt-cancel-error(" ^ show_issue current ^ ")"

let show_command = function
  | M.Load_workflow (id, file) ->
      Printf.sprintf "load(q=%s file=%S)" (show_request id) file
  | M.Read_tracker value ->
      let kind, selected =
        match value.M.selection with
        | M.States names -> ("states", names)
        | M.Ids ids -> ("ids", ids)
      in
      Printf.sprintf "read(q=%s binding=%d terminal=[%s] %s=[%s])"
        (show_request value.M.id) value.M.binding
        (String.concat ";" value.M.terminal)
        kind
        (String.concat ";" selected)
  | M.Start_worker value ->
      Printf.sprintf "start(run=%s issue=%s reference=%s launch=%d attempt=%s)"
        (show_run value.M.run) (show_issue value.M.issue)
        (show_ref value.M.reference)
        value.M.launch (show_int value.M.attempt)
  | M.Stop_worker (id, run, reason) ->
      Printf.sprintf "stop(issue=%S run=%s reason=%s)" id (show_run run)
        (show_cancel reason)
  | M.Remove_workspace (id, reference) ->
      Printf.sprintf "remove(q=%s reference=%s)" (show_request id)
        (show_ref reference)
  | M.Cancel_request id -> Printf.sprintf "cancel-job(q=%s)" (show_request id)
  | M.Arm_poll (id, due) ->
      Printf.sprintf "arm-poll(q=%s due=%d)" (show_request id) due
  | M.Cancel_poll id -> Printf.sprintf "cancel-poll(q=%s)" (show_request id)
  | M.Arm_retry (id, token, due) ->
      Printf.sprintf "arm-retry(issue=%S retry=%s due=%d)" id (show_retry token)
        due
  | M.Cancel_retry (id, token) ->
      Printf.sprintf "cancel-retry(issue=%S retry=%s)" id (show_retry token)
  | M.Report fault -> "report(" ^ show_fault fault ^ ")"

let show_actual = function
  | C.Load_workflow { id; file } ->
      Printf.sprintf "load(q=%s file=%S)" (Request_id.text id)
        (Workflow_path.display file)
  | C.Read_tracker (T.States { id; names; _ }) ->
      Printf.sprintf "read(q=%s states=[%s])" (Request_id.text id)
        (String.concat ";" names)
  | C.Read_tracker (T.Ids { id; ids; _ }) ->
      Printf.sprintf "read(q=%s ids=[%s])" (Request_id.text id)
        (String.concat ";" (List.map issue_id (Issue_id.Set.elements ids)))
  | C.Start_worker value ->
      Printf.sprintf "start(run=%s issue=%S reference=%s)"
        (Run_id.text (F.Agent.run_id value))
        (issue_id (Issue.id (F.Agent.issue value)))
        (show_ref (reference (F.Agent.workspace value)))
  | C.Stop_worker (id, token, reason) ->
      Printf.sprintf "stop(issue=%S run=%s reason=%s)" (issue_id id)
        (Run_id.text token)
        (show_cancel (cancel reason))
  | C.Remove_workspace value ->
      Printf.sprintf "remove(q=%s reference=%s)"
        (Request_id.text value.F.Workspace.request_id)
        (show_ref (reference value.F.Workspace.workspace))
  | C.Cancel_request id -> "cancel-job(q=" ^ Request_id.text id ^ ")"
  | C.Arm_poll (id, due) ->
      Printf.sprintf "arm-poll(q=%s due=%d)" (Request_id.text id) (ticks due)
  | C.Cancel_poll id -> "cancel-poll(q=" ^ Request_id.text id ^ ")"
  | C.Arm_retry (id, token, due) ->
      Printf.sprintf "arm-retry(issue=%S retry=%s due=%d)" (issue_id id)
        (Retry_id.text token) (ticks due)
  | C.Cancel_retry (id, token) ->
      Printf.sprintf "cancel-retry(issue=%S retry=%s)" (issue_id id)
        (Retry_id.text token)
  | C.Report fault ->
      "report("
      ^ (match fault with
        | C.Config_failure _ -> "config"
        | C.Tracker_failure _ -> "tracker"
        | C.Issue_tracker_failure (current, _) ->
            show_fault (M.Issue_tracker_failure (issue current))
        | C.Attempt_failure (current, _) ->
            show_fault (M.Attempt_failure (issue current))
        | C.Attempt_timeout (current, _) ->
            show_fault (M.Attempt_timeout (issue current))
        | C.Attempt_stalled current ->
            show_fault (M.Attempt_stalled (issue current))
        | C.Attempt_cancel_error (current, _) ->
            show_fault (M.Attempt_cancel_error (issue current))
        | C.Planning_failure (current, _) ->
            show_fault (M.Planning_failure (issue current))
        | C.Cleanup_failure (current, _) ->
            show_fault (M.Cleanup_failure (issue current))
        | C.Lifecycle_failure (current, _) ->
            show_fault (M.Lifecycle_failure (issue current)))
      ^ ")"

let show_owner = function
  | M.Worker value ->
      let phase =
        match value.M.phase with
        | M.Starting -> "starting"
        | M.Active -> "active"
        | M.Stopping -> "stopping"
      in
      Printf.sprintf "worker(issue=%s run=%s phase=%s attempt=%s runtime=%dms)"
        (show_issue value.M.issue) (show_run value.M.run) phase
        (show_int value.M.attempt) value.M.seconds_ms
  | M.Retry value ->
      let phase =
        match value.M.phase with
        | M.Waiting due -> Printf.sprintf "waiting(%d)" due
        | M.Refreshing -> "refreshing"
        | M.Parked -> "parked"
      in
      Printf.sprintf "retry(issue=%s token=%s phase=%s attempt=%d)"
        (show_issue value.M.issue) (show_retry value.M.retry) phase
        value.M.attempt
  | M.Cleaning issue -> "cleaning(" ^ show_issue issue ^ ")"

let show_projection (value : M.projection) =
  let mode =
    match value.M.mode with
    | M.Startup -> "startup"
    | M.Serving -> "serving"
    | M.Draining_scope -> "draining"
    | M.Shutting_down -> "shutdown"
  in
  let readiness =
    match value.M.readiness with
    | M.Ready -> "ready"
    | M.Loading -> "loading"
    | M.Invalid -> "invalid"
  in
  Printf.sprintf "mode=%s readiness=%s running=%d slots=%d runtime=%dms\n%s"
    mode readiness value.M.running value.M.available_slots
    value.M.total_runtime_ms
    (String.concat "\n" (List.map show_owner value.M.owners))

let compare_commands tokens expected actual =
  if List.length expected <> List.length actual then
    fail "Command count differs:\nexpected:\n%s\nactual:\n%s"
      (String.concat "\n" (List.map show_command expected))
      (String.concat "\n" (List.map show_actual actual));
  let rec loop index tokens expected actual =
    match (expected, actual) with
    | [], [] -> tokens
    | model :: rest, concrete :: remaining ->
        let tokens = pair tokens model concrete in
        let observed = command tokens concrete in
        if model <> observed then
          fail "Command %d facts/order differ:\nexpected: %s\nactual: %s" index
            (show_command model) (show_command observed);
        loop (index + 1) tokens rest remaining
    | _ -> fail "Command traversal length defect"
  in
  loop 0 tokens expected actual

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

type replay = {
  model : M.state;
  actual : C.state;
  tokens : tokens;
  history : M.command list;
  edges : edge list;
  now : int;
}

let compare now tokens model actual =
  (match M.invariant model with
  | Ok () -> ()
  | Error error -> fail "Oracle invariant: %s" error);
  let expected = M.project ~now model in
  let observed = projection tokens (C.project ~now:(F.instant now) actual) in
  if expected <> observed then
    fail "Owner projection differs:\nexpected:\n%s\nactual:\n%s"
      (show_projection expected) (show_projection observed);
  if M.quiescent model <> C.quiescent actual then
    fail "Quiescence differs: expected=%b actual=%b" (M.quiescent model)
      (C.quiescent actual)

let create profile =
  let model, expected = M.create ~now:0 (config profile) in
  let actual, commands = C.create ~now:(F.instant 0) (F.config profile) in
  let tokens = compare_commands empty_tokens expected commands in
  compare 0 tokens model actual;
  {
    model;
    actual;
    tokens;
    history = expected;
    edges = List.fold_left register_edge [] expected;
    now = 0;
  }

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

let input tokens ~profile = function
  | M.Poll_due q -> C.Poll_due (request tokens q)
  | M.Refresh_requested -> C.Refresh_requested
  | M.Workflow_changed -> C.Workflow_changed
  | M.Workflow_loaded (q, Ok _) ->
      C.Workflow_loaded (request tokens q, Ok (F.config profile))
  | M.Workflow_loaded (q, Error ()) ->
      C.Workflow_loaded (request tokens q, Error F.invalid_config)
  | M.Tracker_completed (q, Ok issues) ->
      C.Tracker_completed
        (request tokens q, F.reply (List.map actual_issue issues))
  | M.Tracker_completed (q, Error ()) ->
      C.Tracker_completed (request tokens q, Error F.tracker_error)
  | M.Worker_started (id, r) -> C.Worker_started (actual_id id, run tokens r)
  | M.Worker_finished (id, r, result) ->
      C.Worker_finished
        (F.completed ~issue:(actual_id id) ~run:(run tokens r) (outcome result))
  | M.Request_canceled q -> C.Request_canceled (request tokens q)
  | M.Retry_due (id, r) -> C.Retry_due (actual_id id, retry tokens r)
  | M.Workspace_removed (q, result) ->
      C.Workspace_removed
        ( request tokens q,
          match result with
          | Ok () -> Ok ()
          | Error () -> Error (Workspace_manager.Filesystem_error F.diagnostic)
        )
  | M.Shutdown -> C.Shutdown

let show_outcome = function
  | M.Succeeded -> "succeeded"
  | M.Failed -> "failed"
  | M.Timed_out -> "timed-out"
  | M.Stalled -> "stalled"
  | M.Canceled -> "canceled"
  | M.Cancel_error -> "cancel-error"

let show_input = function
  | M.Poll_due id -> "poll(q=" ^ show_request id ^ ")"
  | M.Refresh_requested -> "refresh"
  | M.Workflow_changed -> "workflow-change"
  | M.Workflow_loaded (id, result) ->
      let result =
        match result with
        | Error () -> "invalid"
        | Ok config ->
            Printf.sprintf
              "binding=%d scope=%d root=%d launch=%d cap=%d poll=%d"
              config.M.binding config.M.scope config.M.root config.M.launch
              config.M.global_cap config.M.poll_ms
      in
      Printf.sprintf "workflow-loaded(q=%s %s)" (show_request id) result
  | M.Tracker_completed (id, result) ->
      let result =
        match result with
        | Error () -> "error"
        | Ok issues ->
            "[" ^ String.concat ";" (List.map show_issue issues) ^ "]"
      in
      Printf.sprintf "tracker-closed(q=%s %s)" (show_request id) result
  | M.Worker_started (id, run) ->
      Printf.sprintf "worker-started(issue=%S run=%s)" id (show_run run)
  | M.Worker_finished (id, run, outcome) ->
      Printf.sprintf "worker-closed(issue=%S run=%s %s)" id (show_run run)
        (show_outcome outcome)
  | M.Request_canceled id -> "request-closed(q=" ^ show_request id ^ ")"
  | M.Retry_due (id, retry) ->
      Printf.sprintf "retry-due(issue=%S retry=%s)" id (show_retry retry)
  | M.Workspace_removed (id, result) ->
      Printf.sprintf "workspace-closed(q=%s %s)" (show_request id)
        (match result with
        | Ok () -> "ok"
        | Error () -> "error")
  | M.Shutdown -> "shutdown"

let step ~profile ~now replay event =
  let model, expected = M.step ~now event replay.model in
  let actual, commands =
    C.step replay.actual
      (C.event ~now:(F.instant now) (input replay.tokens ~profile event))
  in
  let tokens =
    try compare_commands replay.tokens expected commands
    with Difference message ->
      fail
        "%s\n\
         input: %s\n\
         before:\n\
         %s\n\
         expected commands:\n\
         %s\n\
         actual commands:\n\
         %s"
        message (show_input event)
        (show_projection (M.project ~now replay.model))
        (String.concat "\n" (List.map show_command expected))
        (String.concat "\n" (List.map show_actual commands))
  in
  compare now tokens model actual;
  {
    model;
    actual;
    tokens;
    history = replay.history @ expected;
    edges =
      List.fold_left register_edge (close_edges now event replay.edges) expected;
    now;
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
    let now = replay.now + 1 in
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
        if not (M.quiescent replay.model && C.quiescent replay.actual) then
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
        if Random.State.int random 4 = 0 then replay.history
        else take recent_window (List.rev replay.history)
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
      let now = replay.now + elapsed in
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
      let previous_history = List.length replay.history in
      let next =
        try step ~profile ~now replay event
        with Difference message ->
          fail "seed=%d prefix=%d step=%d\n%s\n%s" seed length index message
            (String.concat "\n" (List.rev trace))
      in
      let effects =
        List.filteri (fun index _ -> index >= previous_history) next.history
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

let model_invalid_reload () =
  let check order =
    let initial, commands = M.create ~now:0 (config F.A) in
    let startup = selected_read commands in
    let serving, _ =
      M.step ~now:1 (M.Tracker_completed (startup, Ok [])) initial
    in
    let checking, commands = M.step ~now:2 M.Refresh_requested serving in
    let fetching, commands =
      M.step ~now:3
        (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
        checking
    in
    let candidate = selected_read commands in
    let canceled, commands = M.step ~now:4 M.Workflow_changed fetching in
    let loader = selected_load commands in
    let first, second =
      match order with
      | Candidate_first ->
          (M.Request_canceled candidate, M.Workflow_loaded (loader, Error ()))
      | Loader_first ->
          (M.Workflow_loaded (loader, Error ()), M.Request_canceled candidate)
    in
    let interim, first_commands = M.step ~now:5 first canceled in
    let closed, last_commands = M.step ~now:6 second interim in
    let effects = first_commands @ last_commands in
    let expected_due = 6 + (config F.A).M.poll_ms in
    let arms_interval =
      List.exists
        (function
          | M.Arm_poll (_, due) -> due = expected_due
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
    if
      List.length effects <> 2
      || (not arms_interval)
      || (not (List.mem (M.Report M.Config_failure) effects))
      || (M.project ~now:6 closed).M.readiness <> M.Invalid
    then
      fail
        "Invalid candidate replacement (%s) must report and arm interval:\n%s"
        (match order with
        | Candidate_first -> "candidate-first"
        | Loader_first -> "loader-first")
        (String.concat "\n" (List.map show_command effects))
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
    let serving, _ =
      M.step ~now:1
        (M.Tracker_completed (selected_read commands, Ok []))
        initial
    in
    let checking, commands = M.step ~now:2 M.Refresh_requested serving in
    let fetching, commands =
      M.step ~now:3
        (M.Workflow_loaded (selected_load commands, Ok (config F.A)))
        checking
    in
    let starting, commands =
      M.step ~now:4
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
      M.step ~now:5 (M.Worker_started (current.M.id, worker.M.run)) starting
    in
    let reconciling, commands = M.step ~now:6 M.Refresh_requested active in
    let reconcile = selected_read commands in
    let loading, commands = M.step ~now:7 M.Workflow_changed reconciling in
    let borrowed = selected_load commands in
    let validating, _ =
      M.step ~now:8 (M.Tracker_completed (reconcile, Ok [ current ])) loading
    in
    let replacing, commands = M.step ~now:9 M.Workflow_changed validating in
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
    let interim, early = M.step ~now:10 first replacing in
    if early <> expected_early then
      fail "Borrowed preflight (%s) advanced before both loaders closed:\n%s"
        (match order with
        | Old_load_first -> "old-load-first"
        | Invalid_load_first -> "invalid-load-first")
        (String.concat "\n" (List.map show_command early));
    let closed, effects = M.step ~now:200 second interim in
    let expected_due = 200 + (config F.A).M.poll_ms in
    let paced =
      match early @ effects with
      | [ report; poll ] -> (
          report = M.Report M.Config_failure
          &&
          match poll with
          | M.Arm_poll (_, due) -> due = expected_due
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
      | [] | [ _ ] | _ :: _ :: _ :: _ -> false
    in
    if (not paced) || (M.project ~now:200 closed).M.readiness <> M.Invalid then
      fail "Closed borrowed preflight must report and reserve one paced poll"
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
