module F = Lifecycle_fixture
module L = F.Lifecycle
module M = Lifecycle_model

let checked = function
  | Ok value -> value
  | Error diagnostic -> Alcotest.fail (Diagnostic.render diagnostic)

let model_checked = function
  | Ok value -> value
  | Error error -> Alcotest.fail error

let config_old = F.config F.Original
let config_new = F.config F.Replacement
let config_declining = F.config F.Declining
let config_other = F.config F.Other_scope
let original = F.issue ~id:"opaque/lifecycle" ~identifier:"LIFE-1" ()
let other = F.issue ~id:"opaque/other" ~identifier:"LIFE-2" ()
let run_one, run_supply = Run_id.Allocator.fresh Run_id.Allocator.empty
let run_two, _ = Run_id.Allocator.fresh run_supply
let retry_one, retry_supply = Retry_id.Allocator.fresh Retry_id.Allocator.empty
let retry_two, _ = Retry_id.Allocator.fresh retry_supply
let request_one, _ = Request_id.Allocator.fresh Request_id.Allocator.empty

let first_plan =
  F.plan config_old ~run:run_one ~issue:original ~attempt:Template.First

let starting () =
  checked (L.start (L.unclaimed original) first_plan ~now:(F.instant 5))

let complete ?(issue = original) ?(run = run_one) outcome =
  F.completed ~issue:(Issue.id issue) ~run outcome

let failure = Agent_runner.Failed (Agent_runner.Port_exit F.diagnostic)
let timeout = Agent_runner.Timed_out (Agent_runner.Turn_silence F.diagnostic)

let canceled reason =
  Agent_runner.Canceled { reason; remote_error = Some F.diagnostic }

let cause = function
  | L.Continuation -> M.Continuation
  | L.Attempt_failed _ -> M.Attempt_failed
  | L.Attempt_timed_out _ -> M.Attempt_timed_out
  | L.Stall -> M.Stalled
  | L.Planning_failed _ -> M.Planning_failed
  | L.Refresh_failed _ -> M.Refresh_failed
  | L.No_slots -> M.No_slots

let attempt value =
  let decimal = Count.decimal (Positive_count.count value) in
  match int_of_string_opt decimal with
  | Some value -> value
  | None -> Alcotest.fail "Bounded fixture attempt escaped int range"

let disposition = function
  | L.Retry_after_close -> M.Retry
  | L.Release_after_close -> M.Release
  | L.Cleanup_after_close -> M.Cleanup

let stop_model = function
  | Stop_reason.Reconcile_terminal -> M.Terminal
  | Stop_reason.Reconcile_inactive -> M.Inactive
  | Stop_reason.Reconcile_missing -> M.Missing
  | Stop_reason.Reconcile_unroutable -> M.Unroutable
  | Stop_reason.Scope_changed -> M.Scope
  | Stop_reason.Stall_detected -> M.Stall
  | Stop_reason.Shutdown_requested -> M.Shutdown

let issue_model issue =
  M.
    {
      id = Issue_id.text (Issue.id issue);
      identifier = Issue_identifier.text (Issue.identifier issue);
      state = Issue.state issue;
      title = Issue.title issue;
    }

let reference_model reference =
  M.Named
    ( Tracker_scope.text (F.Workspace.scope reference),
      Issue_id.text (F.Workspace.issue_id reference),
      Issue_identifier.text (F.Workspace.identifier reference),
      Absolute_path.display
        (Workspace_settings.root (F.Workspace.settings reference)) )

let target_model = function
  | F.Plan.Unnamed scope -> M.Unnamed (Tracker_scope.text scope)
  | F.Plan.Named reference -> reference_model reference

let original_target =
  M.Named
    ( Tracker_scope.text
        (Tracker_registry.Contract.scope (F.Config.tracker config_old)),
      "opaque/lifecycle",
      "LIFE-1",
      "/fixture/root-original" )

let same_view message expected actual =
  if expected <> actual then Alcotest.fail message

let reject message = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail message

let retryable = function
  | L.Retryable value -> value
  | L.Releasable _ | L.Cleanable _ ->
      Alcotest.fail "Expected retryable completion"

let waiting outcome =
  let finished = checked (L.finish_starting (starting ()) (complete outcome)) in
  L.retry (retryable finished) ~retry_id:retry_one ~due:(F.instant 40)

let refreshed outcome = L.settled (L.refresh (waiting outcome))

let start_and_identity () =
  let run = starting () in
  let current =
    F.issue ~state:"Doing" ~title:"Fresh tracker title" ~id:"opaque/lifecycle"
      ~identifier:"LIFE-RENAMED" ()
  in
  let updated = checked (L.replace_issue (L.Starting run) current) in
  Alcotest.(check string)
    "current title" "Fresh tracker title"
    (Issue.title (L.issue updated));
  let active =
    match updated with
    | L.Starting value -> L.activate value
    | L.Active _
    | L.Stopping _
    | L.Waiting _
    | L.Refreshing _
    | L.Parked _
    | L.Cleaning _ -> Alcotest.fail "Issue refresh changed source phase"
  in
  let frozen = F.Plan.request (L.plan active) in
  Alcotest.(check string)
    "launch title stays frozen" "Lifecycle fixture"
    (Issue.title (F.Agent.issue frozen));
  same_view "original reference stays frozen" original_target
    (reference_model (F.Agent.workspace frozen));
  Alcotest.(check bool)
    "start instant preserved" true
    (Clock.Pure.compare (L.started active) (F.instant 5) = 0);
  reject "different issue was accepted"
    (L.start (L.unclaimed other) first_plan ~now:(F.instant 5));
  let renamed = F.issue ~id:"opaque/lifecycle" ~identifier:"LIFE-NEW" () in
  reject "different original identifier was accepted"
    (L.start (L.unclaimed renamed) first_plan ~now:(F.instant 5));
  let follow_up =
    F.plan config_old ~run:run_one ~issue:original
      ~attempt:(Template.Follow_up Positive_count.first)
  in
  reject "Follow_up was accepted for initial start"
    (L.start (L.unclaimed original) follow_up ~now:(F.instant 5));
  reject "different completion run was accepted"
    (L.finish_starting run (complete ~run:run_two Agent_runner.Succeeded));
  reject "different completion issue was accepted"
    (L.finish_starting run (complete ~issue:other Agent_runner.Succeeded));
  reject "different current opaque ID was accepted"
    (L.replace_issue (L.Active active) other)

let terminal_mapping () =
  let outcomes =
    [
      (Agent_runner.Succeeded, Some M.Continuation);
      (failure, Some M.Attempt_failed);
      (timeout, Some M.Attempt_timed_out);
      (Agent_runner.Stalled, Some M.Stalled);
      (canceled Agent_runner.Reconciliation, None);
      (canceled Agent_runner.Scope_change, None);
      (canceled Agent_runner.Host_shutdown, None);
    ]
  in
  List.iter
    (fun (outcome, expected) ->
      let completed = complete outcome in
      let finished =
        checked (L.finish_active (L.activate (starting ())) completed)
      in
      match (expected, finished) with
      | None, L.Releasable value ->
          Alcotest.(check bool)
            "completed witness retained" true
            (L.finished_outcome value == completed);
          ignore (L.release_run value)
      | Some expected, L.Retryable value ->
          same_view "terminal cause" expected (cause (L.finish_cause value));
          Alcotest.(check int)
            "First advances/resets to1" 1
            (attempt (L.next_attempt value));
          Alcotest.(check bool)
            "completed witness retained" true
            (L.finished_outcome value == completed)
      | (None | Some _), (L.Retryable _ | L.Releasable _ | L.Cleanable _) ->
          Alcotest.fail "Wrong transient completion class")
    outcomes;
  let retry = refreshed Agent_runner.Succeeded in
  let planned =
    F.plan config_new ~run:run_two ~issue:original
      ~attempt:(Template.Follow_up Positive_count.first)
  in
  let resumed = checked (L.resume retry planned ~now:(F.instant 50)) in
  List.iter
    (fun (outcome, expected) ->
      let finished =
        checked (L.finish_starting resumed (complete ~run:run_two outcome))
      in
      match (expected, finished) with
      | None, L.Releasable _ -> ()
      | Some expected, L.Retryable value ->
          same_view "follow-up cause" expected (cause (L.finish_cause value));
          Alcotest.(check int)
            "continuation resets, failures advance"
            (if expected = M.Continuation then 1 else 2)
            (attempt (L.next_attempt value))
      | (None | Some _), (L.Retryable _ | L.Releasable _ | L.Cleanable _) ->
          Alcotest.fail "Wrong follow-up completion class")
    outcomes

let disposition_laws () =
  let reasons =
    [
      Stop_reason.Reconcile_terminal;
      Stop_reason.Reconcile_inactive;
      Stop_reason.Reconcile_missing;
      Stop_reason.Reconcile_unroutable;
      Stop_reason.Scope_changed;
      Stop_reason.Stall_detected;
      Stop_reason.Shutdown_requested;
    ]
  in
  List.iter
    (fun reason ->
      let stopped = L.stop_active (L.activate (starting ())) reason in
      let left = L.release_after_close (L.clean_after_close stopped) in
      let right = L.clean_after_close (L.release_after_close stopped) in
      same_view "refinements commute"
        (disposition (L.after_close left))
        (disposition (L.after_close right));
      same_view "cleanup absorbs" M.Cleanup (disposition (L.after_close left));
      same_view "first reason retained" reason (L.stop_reason left);
      same_view "cleanup idempotent" (L.after_close left)
        (L.after_close (L.clean_after_close left));
      same_view "release idempotent"
        (L.after_close (L.release_after_close stopped))
        (L.after_close (L.release_after_close (L.release_after_close stopped)));
      let finished = checked (L.finish_stopping left (complete failure)) in
      match finished with
      | L.Cleanable value ->
          let clean = L.clean_run value ~request_id:request_one in
          let request = L.cleanup_request clean in
          same_view "cleanup original reference" original_target
            (reference_model request.F.Workspace.workspace);
          ignore (L.cleaned clean)
      | L.Retryable _ | L.Releasable _ ->
          Alcotest.fail "Cleanup lost to remote error")
    reasons;
  let stalled = L.stop_starting (starting ()) Stop_reason.Stall_detected in
  let raced =
    retryable
      (checked (L.finish_stopping stalled (complete Agent_runner.Succeeded)))
  in
  same_view "stall survives racing remote success" M.Stalled
    (cause (L.finish_cause raced));
  let release = L.release_after_close stalled in
  match
    checked (L.finish_stopping release (complete Agent_runner.Succeeded))
  with
  | L.Releasable _ -> ()
  | L.Retryable _ | L.Cleanable _ -> Alcotest.fail "Release lost to success"

let parking_and_requeue () =
  let waiting = waiting failure in
  Alcotest.(check bool)
    "due only while waiting" true
    (Clock.Pure.compare (L.due waiting) (F.instant 40) = 0);
  let refresh = L.refresh waiting in
  let parked = L.park (L.settled refresh) in
  let reread = L.reread parked in
  List.iter
    (fun owned ->
      Alcotest.(check string)
        "current issue retained" "opaque/lifecycle"
        (Issue_id.text (Issue.id (L.issue owned))))
    [
      L.Waiting waiting;
      L.Refreshing refresh;
      L.Parked parked;
      L.Refreshing reread;
    ];
  Alcotest.(check bool)
    "park retains timer generation" true
    (Retry_id.equal (L.retry_id parked) retry_one);
  Alcotest.(check int) "park retains attempt" 1 (attempt (L.attempt parked));
  same_view "park retains cause" M.Attempt_failed (cause (L.cause parked));
  same_view "park retains target" original_target
    (target_model (L.retry_target parked));
  List.iter
    (fun (failure, expected) ->
      let queued =
        L.requeue (L.settled reread) failure ~retry_id:retry_two
          ~due:(F.instant 90)
      in
      Alcotest.(check int)
        "requeue advances attempt" 2
        (attempt (L.attempt queued));
      same_view "closed failure category" expected (cause (L.cause queued));
      Alcotest.(check bool)
        "new retry generation" true
        (Retry_id.equal retry_two (L.retry_id queued));
      same_view "old target retained" original_target
        (target_model (L.retry_target queued)))
    [
      (L.Tracker_failed F.tracker_error, M.Refresh_failed);
      (L.Slots_unavailable, M.No_slots);
    ];
  ignore (L.release_parked parked)

let planning_rejections () =
  let bad = F.issue ~id:"opaque/lifecycle" ~identifier:"." () in
  let rejected =
    F.rejection config_old ~run:run_one ~issue:bad ~attempt:Template.First
  in
  let unnamed =
    checked
      (L.reject_start (L.unclaimed bad) rejected ~retry_id:retry_one
         ~due:(F.instant 40))
  in
  (match L.retry_target unnamed with
  | F.Plan.Unnamed _ -> ()
  | F.Plan.Named _ ->
      Alcotest.fail "Unnamed rejection acquired cleanup authority");
  (match
     L.terminal_retry (L.settled (L.refresh unnamed)) ~request_id:request_one
   with
  | L.Release _ -> ()
  | L.Cleanup _ -> Alcotest.fail "Unnamed retry authorized deletion");
  let named =
    F.rejection config_declining ~run:run_one ~issue:original
      ~attempt:Template.First
  in
  let waiting =
    checked
      (L.reject_start (L.unclaimed original) named ~retry_id:retry_one
         ~due:(F.instant 40))
  in
  (match L.retry_target waiting with
  | F.Plan.Named reference ->
      Alcotest.(check string)
        "named pre-worker reference" "/fixture/root-declining"
        (Absolute_path.display
           (Workspace_settings.root (F.Workspace.settings reference)))
  | F.Plan.Unnamed _ -> Alcotest.fail "Named rejection discarded reference");
  let refresh = refreshed Agent_runner.Succeeded in
  let rejected =
    F.rejection config_declining ~run:run_two ~issue:original
      ~attempt:(Template.Follow_up Positive_count.first)
  in
  let again =
    checked
      (L.reject_resume refresh rejected ~retry_id:retry_two ~due:(F.instant 90))
  in
  Alcotest.(check int) "resume rejection advances" 2 (attempt (L.attempt again));
  same_view "resume rejection keeps old reference" original_target
    (target_model (L.retry_target again));
  same_view "planning cause" M.Planning_failed (cause (L.cause again));
  reject "different rejected issue accepted"
    (L.reject_start (L.unclaimed other) named ~retry_id:retry_one
       ~due:(F.instant 40))

let refreshed_identity () =
  let refresh = L.refresh (waiting Agent_runner.Succeeded) in
  let current =
    F.issue ~state:"Doing" ~title:"Reconciled" ~id:"opaque/lifecycle"
      ~identifier:"LIFE-NEW" ()
  in
  let refreshed =
    match checked (L.replace_issue (L.Refreshing refresh) current) with
    | L.Refreshing value -> L.settled value
    | L.Starting _
    | L.Active _
    | L.Stopping _
    | L.Waiting _
    | L.Parked _
    | L.Cleaning _ -> Alcotest.fail "Issue refresh changed source phase"
  in
  let planned =
    F.plan config_new ~run:run_two ~issue:current
      ~attempt:(Template.Follow_up Positive_count.first)
  in
  let resumed = checked (L.resume refreshed planned ~now:(F.instant 50)) in
  Alcotest.(check string)
    "new launch uses fresh identifier" "LIFE-NEW"
    (Issue_identifier.text (Issue.identifier (L.issue (L.Starting resumed))));
  let wrong_attempt =
    F.plan config_new ~run:run_two ~issue:current
      ~attempt:(Template.Follow_up (F.positive 2))
  in
  reject "resume skipped attempt"
    (L.resume refreshed wrong_attempt ~now:(F.instant 50));
  let wrong_scope =
    F.plan config_other ~run:run_two ~issue:current
      ~attempt:(Template.Follow_up Positive_count.first)
  in
  reject "resume crossed tracker scope"
    (L.resume refreshed wrong_scope ~now:(F.instant 50));
  match L.terminal_retry refreshed ~request_id:request_one with
  | L.Cleanup clean ->
      let request = L.cleanup_request clean in
      same_view "terminal cleanup preserves original identity" original_target
        (reference_model request.F.Workspace.workspace);
      Alcotest.(check string)
        "cleanup keeps current issue" "Reconciled"
        (Issue.title (L.issue (L.Cleaning clean)))
  | L.Release _ -> Alcotest.fail "Named retry did not reserve cleanup"

let startup_cleanup () =
  let reference = F.Agent.workspace (F.Plan.request first_plan) in
  let request =
    { F.Workspace.request_id = request_one; workspace = reference }
  in
  let clean = checked (L.clean_startup (L.unclaimed original) request) in
  Alcotest.(check bool)
    "cleanup request fence retained" true
    (Request_id.equal request_one
       (L.cleanup_request clean).F.Workspace.request_id);
  reject "startup cleanup crossed opaque ID"
    (L.clean_startup (L.unclaimed other) request);
  let renamed = F.issue ~id:"opaque/lifecycle" ~identifier:"LIFE-NEW" () in
  reject "startup cleanup crossed original identifier"
    (L.clean_startup (L.unclaimed renamed) request);
  ignore (L.cleaned clean)

let tests =
  [
    Alcotest.test_case "start/activate and keyed identity" `Quick
      start_and_identity;
    Alcotest.test_case "closed outcome classes and exact attempts" `Quick
      terminal_mapping;
    Alcotest.test_case "stop refinements preserve cause and cleanup" `Quick
      disposition_laws;
    Alcotest.test_case "refresh/park/reread and requeue" `Quick
      parking_and_requeue;
    Alcotest.test_case "planning rejection has no worker completion" `Quick
      planning_rejections;
    Alcotest.test_case "fresh issue and original retry authority" `Quick
      refreshed_identity;
    Alcotest.test_case "startup cleanup checks original identity" `Quick
      startup_cleanup;
  ]

type machine = Initial of Issue.t | Owned of L.owned | Done

type tokens = {
  runs : (int * Run_id.t) list;
  retries : (int * Retry_id.t) list;
  requests : (int * Request_id.t) list;
  run_supply : Run_id.Allocator.t;
  retry_supply : Retry_id.Allocator.t;
  request_supply : Request_id.Allocator.t;
}

let empty_tokens =
  {
    runs = [];
    retries = [];
    requests = [];
    run_supply = Run_id.Allocator.empty;
    retry_supply = Retry_id.Allocator.empty;
    request_supply = Request_id.Allocator.empty;
  }

let allocate tag tokens =
  let run, run_supply = Run_id.Allocator.fresh tokens.run_supply in
  let retry, retry_supply = Retry_id.Allocator.fresh tokens.retry_supply in
  let request, request_supply =
    Request_id.Allocator.fresh tokens.request_supply
  in
  ( {
      runs = (tag, run) :: tokens.runs;
      retries = (tag, retry) :: tokens.retries;
      requests = (tag, request) :: tokens.requests;
      run_supply;
      retry_supply;
      request_supply;
    },
    run,
    retry,
    request )

let token_tag equal value bindings =
  match
    List.find_opt (fun (_, candidate) -> equal value candidate) bindings
  with
  | Some (tag, _) -> tag
  | None -> Alcotest.fail "Observed unallocated lifecycle token"

let count_ms instant =
  let text = Count.decimal (Clock.Pure.nanoseconds instant) in
  match int_of_string_opt text with
  | Some value -> value / 1_000_000
  | None -> Alcotest.fail "Bounded model tick escaped int range"

let planned_attempt = function
  | Template.First -> None
  | Template.Follow_up value -> Some (attempt value)

let profile_tag request =
  match F.Agent.prompt_source request with
  | "original" -> 0
  | "replacement" -> 1
  | "decline" -> 2
  | "other" -> 3
  | _ -> Alcotest.fail "Unknown fixed fixture profile"

let binding_tag plan =
  let binding = F.Plan.binding plan in
  if Tracker_registry.Contract.equal binding (F.Config.tracker config_old) then
    0
  else if Tracker_registry.Contract.equal binding (F.Config.tracker config_new)
  then 1
  else if
    Tracker_registry.Contract.equal binding (F.Config.tracker config_declining)
  then 2
  else if
    Tracker_registry.Contract.equal binding (F.Config.tracker config_other)
  then 3
  else Alcotest.fail "Observed unknown frozen binding"

let project_plan tokens plan =
  let request = F.Plan.request plan in
  let profile = profile_tag request in
  let observed = binding_tag plan in
  if observed <> profile then
    QCheck2.Test.fail_reportf
      "Frozen binding differs from launch profile: expected %d, observed %d"
      profile observed;
  {
    M.run = token_tag Run_id.equal (F.Agent.run_id request) tokens.runs;
    issue = issue_model (F.Agent.issue request);
    target = reference_model (F.Agent.workspace request);
    attempt = planned_attempt (F.Agent.attempt request);
    profile;
  }

let project tokens = function
  | Initial issue -> M.Unclaimed (issue_model issue)
  | Done -> M.Released
  | Owned owned -> (
      let current = issue_model (L.issue owned) in
      let worker phase run =
        M.Worker
          {
            M.current;
            plan = project_plan tokens (L.plan run);
            phase;
            started = count_ms (L.started run);
          }
      in
      let retry phase retry =
        M.Retry_owner
          {
            M.current;
            target = target_model (L.retry_target retry);
            token = token_tag Retry_id.equal (L.retry_id retry) tokens.retries;
            attempt = attempt (L.attempt retry);
            cause = cause (L.cause retry);
            phase;
          }
      in
      match owned with
      | L.Starting run -> worker M.Starting run
      | L.Active run -> worker M.Active run
      | L.Stopping run ->
          worker
            (M.Stopping
               (stop_model (L.stop_reason run), disposition (L.after_close run)))
            run
      | L.Waiting value -> retry (M.Waiting (count_ms (L.due value))) value
      | L.Refreshing value -> retry M.Refreshing value
      | L.Parked value -> retry M.Parked value
      | L.Cleaning value ->
          let request = L.cleanup_request value in
          M.Cleaning
            ( current,
              reference_model request.F.Workspace.workspace,
              token_tag Request_id.equal request.F.Workspace.request_id
                tokens.requests ))

let expected_plan profile run current attempt =
  let root =
    match profile with
    | 0 -> "/fixture/root-original"
    | 1 -> "/fixture/root-replacement"
    | 2 -> "/fixture/root-declining"
    | _ -> Alcotest.fail "Unknown bounded model profile"
  in
  let scope =
    Tracker_scope.text
      (Tracker_registry.Contract.scope (F.Config.tracker config_old))
  in
  {
    M.run;
    issue = current;
    target = M.Named (scope, current.M.id, current.M.identifier, root);
    attempt;
    profile;
  }

let current_issue = function
  | Initial issue -> issue
  | Owned owner -> L.issue owner
  | Done -> original

let stop_choice value =
  match value mod 7 with
  | 0 -> Stop_reason.Reconcile_terminal
  | 1 -> Stop_reason.Reconcile_inactive
  | 2 -> Stop_reason.Reconcile_missing
  | 3 -> Stop_reason.Reconcile_unroutable
  | 4 -> Stop_reason.Scope_changed
  | 5 -> Stop_reason.Stall_detected
  | _ -> Stop_reason.Shutdown_requested

let outcome_choice value =
  match value mod 5 with
  | 0 -> (Agent_runner.Succeeded, M.Succeeded)
  | 1 -> (failure, M.Failed)
  | 2 -> (timeout, M.Timed_out)
  | 3 -> (Agent_runner.Stalled, M.Stalled_outcome)
  | _ -> (canceled Agent_runner.Reconciliation, M.Canceled)

let close owner completed =
  match owner with
  | L.Starting run -> checked (L.finish_starting run completed)
  | L.Active run -> checked (L.finish_active run completed)
  | L.Stopping run -> checked (L.finish_stopping run completed)
  | L.Waiting _ | L.Refreshing _ | L.Parked _ | L.Cleaning _ ->
      Alcotest.fail "Model attempted completion outside worker source"

let completion_state value retry due request =
  match value with
  | L.Retryable value ->
      Owned (L.Waiting (L.retry value ~retry_id:retry ~due:(F.instant due)))
  | L.Releasable value ->
      ignore (L.release_run value);
      Done
  | L.Cleanable value ->
      Owned (L.Cleaning (L.clean_run value ~request_id:request))

let replace_pair model actual current =
  let updated =
    M.
      {
        id = current.id;
        identifier = current.identifier;
        state = current.state;
        title = current.title;
      }
  in
  let checked_issue =
    F.issue ~id:updated.M.id ~identifier:updated.M.identifier
      ~state:updated.M.state ~title:updated.M.title ()
  in
  match actual with
  | Owned owner ->
      ( model_checked (M.replace_issue model updated),
        Owned (checked (L.replace_issue owner checked_issue)) )
  | Initial _ | Done -> Alcotest.fail "Model refresh outside owned source"

(* Each operation follows its model source, independently of the implementation.
   Refreshed/completion witnesses are consumed inside this atomic operation. *)
let show_issue (issue : M.issue) =
  Printf.sprintf "%S/%S %S title=%S" issue.M.id issue.M.identifier issue.M.state
    issue.M.title

let show_target = function
  | M.Unnamed scope -> Printf.sprintf "unnamed(%S)" scope
  | M.Named (scope, id, identifier, root) ->
      Printf.sprintf "named(%S,%S,%S,%S)" scope id identifier root

let show_stop = function
  | M.Terminal -> "terminal"
  | M.Inactive -> "inactive"
  | M.Missing -> "missing"
  | M.Unroutable -> "unroutable"
  | M.Scope -> "scope"
  | M.Stall -> "stall"
  | M.Shutdown -> "shutdown"

let show_disposition = function
  | M.Retry -> "retry"
  | M.Release -> "release"
  | M.Cleanup -> "cleanup"

let show_cause = function
  | M.Continuation -> "continuation"
  | M.Attempt_failed -> "failed"
  | M.Attempt_timed_out -> "timed_out"
  | M.Stalled -> "stalled"
  | M.Planning_failed -> "planning_failed"
  | M.Refresh_failed -> "refresh_failed"
  | M.No_slots -> "no_slots"

let show_view = function
  | M.Unclaimed issue -> "unclaimed " ^ show_issue issue
  | M.Released -> "released"
  | M.Cleaning (issue, target, request) ->
      Printf.sprintf "cleaning request=%d %s %s" request (show_issue issue)
        (show_target target)
  | M.Worker worker ->
      let phase =
        match worker.M.phase with
        | M.Starting -> "starting"
        | M.Active -> "active"
        | M.Stopping (reason, disposition) ->
            "stopping(" ^ show_stop reason ^ ","
            ^ show_disposition disposition
            ^ ")"
      in
      let attempt =
        match worker.M.plan.M.attempt with
        | None -> "first"
        | Some n -> string_of_int n
      in
      Printf.sprintf
        "%s run=%d attempt=%s profile=%d start=%d current=%s launch=%s \
         target=%s"
        phase worker.M.plan.M.run attempt worker.M.plan.M.profile
        worker.M.started
        (show_issue worker.M.current)
        (show_issue worker.M.plan.M.issue)
        (show_target worker.M.plan.M.target)
  | M.Retry_owner retry ->
      let phase =
        match retry.M.phase with
        | M.Waiting due -> "waiting(" ^ string_of_int due ^ ")"
        | M.Refreshing -> "refreshing"
        | M.Refreshed -> "refreshed"
        | M.Parked -> "parked"
      in
      Printf.sprintf "%s retry=%d attempt=%d cause=%s current=%s target=%s"
        phase retry.M.token retry.M.attempt (show_cause retry.M.cause)
        (show_issue retry.M.current)
        (show_target retry.M.target)

let print_program operations =
  String.concat "\n"
    (List.mapi
       (fun index (code, value) ->
         Printf.sprintf "%d: (%d,%d)" (index + 1) code value)
       operations)

let stream_step tag code value tokens model actual =
  let tokens, run, retry, request = allocate tag tokens in
  let due = tag + 40 in
  let current = current_issue actual in
  let result =
    match M.view model with
    | M.Unclaimed issue -> (
        match actual with
        | Initial source ->
            if code mod 4 = 0 then
              let rejected =
                F.rejection config_declining ~run ~issue:source
                  ~attempt:Template.First
              in
              let planned = expected_plan 2 tag issue None in
              ( model_checked
                  (M.reject_start model planned ~target:planned.M.target
                     ~token:tag ~due),
                Owned
                  (L.Waiting
                     (checked
                        (L.reject_start (L.unclaimed source) rejected
                           ~retry_id:retry ~due:(F.instant due)))) )
            else
              let profile, config =
                if code mod 2 = 0 then (0, config_old) else (1, config_new)
              in
              let planned =
                F.plan config ~run ~issue:source ~attempt:Template.First
              in
              ( model_checked
                  (M.start model
                     (expected_plan profile tag issue None)
                     ~now:tag),
                Owned
                  (L.Starting
                     (checked
                        (L.start (L.unclaimed source) planned
                           ~now:(F.instant tag)))) )
        | Owned _ | Done -> Alcotest.fail "Unclaimed projection mismatch")
    | M.Worker worker -> (
        match actual with
        | Owned owner -> (
            let replace () =
              replace_pair model actual
                {
                  worker.M.current with
                  M.identifier = "LIFE-RENAMED-" ^ string_of_int value;
                  M.title = "Changed-" ^ string_of_int value;
                  M.state = "Doing";
                }
            in
            let finish () =
              let reported, expected = outcome_choice value in
              let original_run =
                match owner with
                | L.Starting source ->
                    F.Agent.run_id (F.Plan.request (L.plan source))
                | L.Active source ->
                    F.Agent.run_id (F.Plan.request (L.plan source))
                | L.Stopping source ->
                    F.Agent.run_id (F.Plan.request (L.plan source))
                | L.Waiting _ | L.Refreshing _ | L.Parked _ | L.Cleaning _ ->
                    Alcotest.fail "Worker phase mismatch"
              in
              let completed =
                F.completed ~issue:(Issue.id current) ~run:original_run reported
              in
              ( model_checked
                  (M.finish model ~issue_id:worker.M.plan.M.issue.M.id
                     ~run:worker.M.plan.M.run expected ~token:tag ~due
                     ~cleanup:tag),
                completion_state (close owner completed) retry due request )
            in
            match worker.M.phase with
            | M.Starting ->
                if code mod 4 = 0 then
                  match owner with
                  | L.Starting source ->
                      ( model_checked (M.activate model),
                        Owned (L.Active (L.activate source)) )
                  | L.Active _
                  | L.Stopping _
                  | L.Waiting _
                  | L.Refreshing _
                  | L.Parked _
                  | L.Cleaning _ -> Alcotest.fail "Starting mismatch"
                else if code mod 4 = 1 then
                  let reason = stop_choice value in
                  match owner with
                  | L.Starting source ->
                      ( model_checked (M.stop model (stop_model reason)),
                        Owned (L.Stopping (L.stop_starting source reason)) )
                  | L.Active _
                  | L.Stopping _
                  | L.Waiting _
                  | L.Refreshing _
                  | L.Parked _
                  | L.Cleaning _ -> Alcotest.fail "Starting mismatch"
                else if code mod 4 = 2 then replace ()
                else finish ()
            | M.Active ->
                if code mod 3 = 0 then
                  let reason = stop_choice value in
                  match owner with
                  | L.Active source ->
                      ( model_checked (M.stop model (stop_model reason)),
                        Owned (L.Stopping (L.stop_active source reason)) )
                  | L.Starting _
                  | L.Stopping _
                  | L.Waiting _
                  | L.Refreshing _
                  | L.Parked _
                  | L.Cleaning _ -> Alcotest.fail "Active mismatch"
                else if code mod 3 = 1 then replace ()
                else finish ()
            | M.Stopping _ ->
                if code mod 4 < 2 then
                  match owner with
                  | L.Stopping source ->
                      if code mod 4 = 0 then
                        ( model_checked (M.refine model M.Cleanup),
                          Owned (L.Stopping (L.clean_after_close source)) )
                      else
                        ( model_checked (M.refine model M.Release),
                          Owned (L.Stopping (L.release_after_close source)) )
                  | L.Starting _
                  | L.Active _
                  | L.Waiting _
                  | L.Refreshing _
                  | L.Parked _
                  | L.Cleaning _ -> Alcotest.fail "Stopping mismatch"
                else if code mod 4 = 2 then replace ()
                else finish ())
        | Initial _ | Done -> Alcotest.fail "Worker projection mismatch")
    | M.Retry_owner source -> (
        match actual with
        | Owned owner -> (
            match source.M.phase with
            | M.Waiting _ -> (
                match owner with
                | L.Waiting waiting ->
                    if code mod 3 = 0 then
                      ( model_checked (M.refresh model),
                        Owned (L.Refreshing (L.refresh waiting)) )
                    else if code mod 3 = 1 then (
                      ignore (L.release_waiting waiting);
                      (model_checked (M.release model), Done))
                    else
                      replace_pair model actual
                        {
                          source.M.current with
                          M.title = "Retry-current";
                          M.state = "Doing";
                        }
                | L.Starting _
                | L.Active _
                | L.Stopping _
                | L.Refreshing _
                | L.Parked _
                | L.Cleaning _ -> Alcotest.fail "Waiting mismatch")
            | M.Parked -> (
                match owner with
                | L.Parked parked ->
                    if code mod 2 = 0 then
                      ( model_checked (M.reread model),
                        Owned (L.Refreshing (L.reread parked)) )
                    else (
                      ignore (L.release_parked parked);
                      (model_checked (M.release model), Done))
                | L.Starting _
                | L.Active _
                | L.Stopping _
                | L.Waiting _
                | L.Refreshing _
                | L.Cleaning _ -> Alcotest.fail "Parked mismatch")
            | M.Refreshed ->
                Alcotest.fail "Transient Refreshed escaped an operation"
            | M.Refreshing -> (
                match owner with
                | L.Refreshing refreshing -> (
                    let fresh_model = model_checked (M.settled model) in
                    let fresh = L.settled refreshing in
                    match code mod 7 with
                    | 0 ->
                        ( model_checked (M.park fresh_model),
                          Owned (L.Parked (L.park fresh)) )
                    | 1 ->
                        ( model_checked
                            (M.requeue fresh_model M.Refresh_failed ~token:tag
                               ~due),
                          Owned
                            (L.Waiting
                               (L.requeue fresh
                                  (L.Tracker_failed F.tracker_error)
                                  ~retry_id:retry ~due:(F.instant due))) )
                    | 2 ->
                        ( model_checked
                            (M.requeue fresh_model M.No_slots ~token:tag ~due),
                          Owned
                            (L.Waiting
                               (L.requeue fresh L.Slots_unavailable
                                  ~retry_id:retry ~due:(F.instant due))) )
                    | 3 ->
                        let planned =
                          F.plan config_new ~run ~issue:current
                            ~attempt:
                              (Template.Follow_up (F.positive source.M.attempt))
                        in
                        ( model_checked
                            (M.resume fresh_model
                               (expected_plan 1 tag source.M.current
                                  (Some source.M.attempt))
                               ~now:tag),
                          Owned
                            (L.Starting
                               (checked
                                  (L.resume fresh planned ~now:(F.instant tag))))
                        )
                    | 4 ->
                        let rejected =
                          F.rejection config_declining ~run ~issue:current
                            ~attempt:
                              (Template.Follow_up (F.positive source.M.attempt))
                        in
                        ( model_checked
                            (M.reject_resume fresh_model
                               (expected_plan 2 tag source.M.current
                                  (Some source.M.attempt))
                               ~token:tag ~due),
                          Owned
                            (L.Waiting
                               (checked
                                  (L.reject_resume fresh rejected
                                     ~retry_id:retry ~due:(F.instant due)))) )
                    | 5 ->
                        ( model_checked (M.terminal fresh_model ~cleanup:tag),
                          match L.terminal_retry fresh ~request_id:request with
                          | L.Release _ -> Done
                          | L.Cleanup value -> Owned (L.Cleaning value) )
                    | _ ->
                        ignore (L.release_refreshed fresh);
                        (model_checked (M.release fresh_model), Done))
                | L.Starting _
                | L.Active _
                | L.Stopping _
                | L.Waiting _
                | L.Parked _
                | L.Cleaning _ -> Alcotest.fail "Refreshing mismatch"))
        | Initial _ | Done -> Alcotest.fail "Retry projection mismatch")
    | M.Cleaning (issue, _, _) -> (
        match actual with
        | Owned (L.Cleaning clean) ->
            if code mod 2 = 0 then (
              ignore (L.cleaned clean);
              (model_checked (M.cleaned model), Done))
            else
              replace_pair model actual
                { issue with M.title = "Cleanup-current" }
        | Initial _ | Done
        | Owned
            ( L.Starting _
            | L.Active _
            | L.Stopping _
            | L.Waiting _
            | L.Refreshing _
            | L.Parked _ ) -> Alcotest.fail "Cleanup projection mismatch")
    | M.Released -> (M.unclaimed (issue_model original), Initial original)
  in
  let next_model, next_actual = result in
  let expected = M.view next_model in
  let observed = project tokens next_actual in
  if expected <> observed then
    Alcotest.failf
      "Lifecycle mismatch at step %d operation (%d,%d)\n\
       expected: %s\n\
       observed: %s"
      tag code value (show_view expected) (show_view observed);
  (* A retained prefix must stay immutable after the transition. *)
  same_view "Retained model/implementation prefix changed" (M.view model)
    (project tokens actual);
  (tokens, next_model, next_actual)

let replay operations =
  ignore
    (List.fold_left
       (fun (tag, tokens, model, actual) (code, value) ->
         let tokens, model, actual =
           stream_step tag code value tokens model actual
         in
         (tag + 1, tokens, model, actual))
       (1, empty_tokens, M.unclaimed (issue_model original), Initial original)
       operations);
  true

let properties =
  (* Sample long runs; shrink their lengths toward zero for short replay traces. *)
  let lengths =
    QCheck2.Gen.set_shrink
      (QCheck2.Shrink.int_towards 0)
      QCheck2.Gen.(int_range 500 600)
  in
  [
    QCheck2.Test.make
      ~name:"lifecycle agrees after every generated source transition"
      ~print:print_program ~count:100
      QCheck2.Gen.(list_size lengths (pair (int_range 0 19) (int_range 0 10)))
      replay;
  ]
