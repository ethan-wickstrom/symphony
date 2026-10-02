module F = Core_fixture
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

module Make
    (Agent :
      Agent_runner.PURE
        with module Issue = Issue
         and module Path = Core_fixture.Path
         and type workspace = Core_fixture.Workspace.reference
         and type request = Core_fixture.Agent.request)
    (C :
      Orchestrator.S
        with type config = Core_fixture.Config.t
         and type instant = Clock.Pure.instant
         and type tracker_request = Tracker_registry.Contract.request
         and type tracker_reply = Tracker_registry.Contract.reply
         and type agent_request = Agent.request
         and type agent_completed = Agent.completed
         and type workspace_cleanup = Core_fixture.Workspace.cleanup) =
struct
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
        if List.exists (fun (_, previous) -> equal previous actual) bindings
        then fail "%s token was reused" kind;
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
    match
      List.find_opt (fun (_, concrete) -> equal concrete actual) bindings
    with
    | Some (model, _) -> model
    | None -> fail "Unexpected concrete %s token" kind

  let model_request tokens actual =
    model_token "request" Request_id.equal actual tokens.requests

  let model_run tokens actual =
    model_token "run" Run_id.equal actual tokens.runs

  let model_retry tokens actual =
    model_token "retry" Retry_id.equal actual tokens.retries

  let pair tokens expected actual =
    let q model concrete =
      {
        tokens with
        requests =
          bind "request" Request_id.equal model concrete tokens.requests;
      }
    in
    match (expected, actual) with
    | M.Load_workflow (id, _), C.Load_workflow { id = concrete; _ }
    | ( M.Remove_workspace (id, _),
        C.Remove_workspace { F.Workspace.request_id = concrete; _ } )
    | M.Arm_poll (id, _), C.Arm_poll (concrete, _) -> q id concrete
    | ( M.Read_tracker { M.id; _ },
        C.Read_tracker
          (T.States { id = concrete; _ } | T.Ids { id = concrete; _ }) ) ->
        q id concrete
    | M.Start_worker { M.run; _ }, C.Start_worker value ->
        {
          tokens with
          runs = bind "run" Run_id.equal run (Agent.run_id value) tokens.runs;
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
      Absolute_path.display
        (Workspace_settings.root (F.Workspace.settings value))
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
      match Agent.prompt_source value with
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
      (Agent_settings.command (Agent.agent value));
    equal "/fixture/core/WORKFLOW.md"
      (Workflow_path.display (Agent.prompt_file value));
    let env =
      Environment.bindings (F.Workspace.environment (Agent.workspace value))
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
            M.issue = issue (Agent.issue value);
            M.run = model_run tokens (Agent.run_id value);
            M.reference = reference (Agent.workspace value);
            M.launch = launch value;
            M.attempt = attempt (Agent.attempt value);
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
          | C.Planning_failure (current, _) ->
              M.Planning_failure (issue current)
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
          (Run_id.text (Agent.run_id value))
          (issue_id (Issue.id (Agent.issue value)))
          (show_ref (reference (Agent.workspace value)))
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
            fail "Command %d facts/order differ:\nexpected: %s\nactual: %s"
              index (show_command model) (show_command observed);
          loop (index + 1) tokens rest remaining
      | _ -> fail "Command traversal length defect"
    in
    loop 0 tokens expected actual

  let checked_config value =
    match
      List.find_opt
        (fun profile -> F.Config.equal (F.config profile) value)
        profiles
    with
    | Some profile -> config profile
    | None -> fail "Unexpected checked workflow fixture"

  let model_outcome = function
    | Agent_runner.Succeeded -> M.Succeeded
    | Agent_runner.Failed _ -> M.Failed
    | Agent_runner.Timed_out _ -> M.Timed_out
    | Agent_runner.Stalled -> M.Stalled
    | Agent_runner.Canceled { remote_error = None; _ } -> M.Canceled
    | Agent_runner.Canceled { remote_error = Some _; _ } -> M.Cancel_error

  let decode tokens = function
    | C.Poll_due id -> M.Poll_due (model_request tokens id)
    | C.Refresh_requested -> M.Refresh_requested
    | C.Workflow_changed -> M.Workflow_changed
    | C.Workflow_loaded (id, result) ->
        M.Workflow_loaded
          ( model_request tokens id,
            match result with
            | Ok value -> Ok (checked_config value)
            | Error _ -> Error () )
    | C.Tracker_completed (id, result) ->
        M.Tracker_completed
          ( model_request tokens id,
            match result with
            | Ok values ->
                Ok
                  (List.map
                     (fun (_, value) -> issue value)
                     (Issue_id.Map.bindings values))
            | Error _ -> Error () )
    | C.Worker_started (id, run) ->
        M.Worker_started (issue_id id, model_run tokens run)
    | C.Worker_finished completed ->
        M.Worker_finished
          ( issue_id (Agent.completed_issue completed),
            model_run tokens (Agent.completed_run completed),
            model_outcome (Agent.outcome completed) )
    | C.Request_canceled id -> M.Request_canceled (model_request tokens id)
    | C.Retry_due (id, retry) ->
        M.Retry_due (issue_id id, model_retry tokens retry)
    | C.Workspace_removed (id, result) ->
        M.Workspace_removed
          ( model_request tokens id,
            match result with
            | Ok () -> Ok ()
            | Error _ -> Error () )
    | C.Shutdown -> M.Shutdown

  type t = {
    model : M.state;
    tokens : tokens;
    history : M.command list;
    time : int;
  }

  let compare now tokens model actual =
    (match M.invariant model with
    | Ok () -> ()
    | Error error -> fail "Oracle invariant: %s" error);
    let expected = M.project ~now model in
    let observed = projection tokens actual in
    if expected <> observed then
      fail "Owner projection differs:\nexpected:\n%s\nactual:\n%s"
        (show_projection expected) (show_projection observed)

  let initial ~profile ~now ~commands ~projection =
    let time = ticks now in
    let model, expected = M.create ~now:time (config profile) in
    let tokens = compare_commands empty_tokens expected commands in
    compare time tokens model projection;
    ({ model; tokens; history = expected; time }, expected)

  let accept value ~now ~input ~commands ~projection =
    let time = ticks now in
    let event = decode value.tokens input in
    let model, expected = M.step ~now:time event value.model in
    let tokens =
      try compare_commands value.tokens expected commands
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
          (show_projection (M.project ~now:time value.model))
          (String.concat "\n" (List.map show_command expected))
          (String.concat "\n" (List.map show_actual commands))
    in
    compare time tokens model projection;
    ( { model; tokens; history = value.history @ expected; time },
      event,
      expected )

  let request value id = request value.tokens id
  let run value id = run value.tokens id
  let retry value id = retry value.tokens id
  let time value = value.time
  let history value = value.history
  let quiescent value = M.quiescent value.model

  let check_quiescent value ~actual =
    let expected = quiescent value in
    if expected <> actual then
      fail "Quiescence differs: expected=%b actual=%b" expected actual
end
