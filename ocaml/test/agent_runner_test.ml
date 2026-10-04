module D = Agent_test_driver
module Runner = Codex_runner.Make (D.Workspace) (D.Process) (Clock_posix)

let request ?(max_turns = 3)
    ?(prompt = "FULL-TASK-ONLY {{ issue.identifier }}: {{ issue.title }}") () =
  match
    Runner.request ~run_id:(D.fresh_run ()) ~issue:(D.issue ())
      ~workspace:(D.reference ()) ~agent:(D.settings ~max_turns ())
      ~prompt_file:D.prompt_file ~prompt_source:prompt ~attempt:Template.First
  with
  | Ok value -> value
  | Error _ -> Alcotest.fail "Runner test request was rejected"

let event_tag = function
  | D.Launch _ -> "launch"
  | D.Write _ -> "write"
  | D.Read_stdout _ -> "stdout"
  | D.Read_stderr _ -> "stderr"
  | D.Process_closing -> "process-closing"
  | D.Process_closed -> "process-closed"
  | D.Workspace_acquired -> "workspace"
  | D.After_run -> "after-run"
  | D.Lease_closing -> "lease-closing"
  | D.Lease_released -> "lease-released"

let notice_tag progress =
  match Runner.notice progress with
  | Runner.Preparing -> "preparing"
  | Runner.Workspace_ready _ -> "workspace-ready"
  | Runner.Rendering -> "rendering"
  | Runner.Starting -> "starting"
  | Runner.Protocol event -> (
      match event with
      | Agent_runner.Session_started _ -> "session-started"
      | Agent_runner.Turn_started _ -> "turn-started"
      | Agent_runner.Turn_completed _ -> "turn-completed"
      | Agent_runner.Output _ -> "output"
      | Agent_runner.Usage_report _ -> "usage"
      | Agent_runner.Rate_limits _ -> "rate-limits"
      | Agent_runner.Unsupported_tool _ -> "unsupported-tool")

let success completed =
  match Runner.outcome completed with
  | Agent_runner.Succeeded -> ()
  | Agent_runner.Failed _
  | Agent_runner.Timed_out _
  | Agent_runner.Stalled
  | Agent_runner.Canceled _ ->
      Alcotest.fail "Expected successful closed attempt"

let canceled reason completed =
  match Runner.outcome completed with
  | Agent_runner.Canceled { reason = actual; remote_error = _ } ->
      Alcotest.check Alcotest.bool "original cancellation cause" true
        (actual = reason)
  | Agent_runner.Succeeded
  | Agent_runner.Failed _
  | Agent_runner.Timed_out _
  | Agent_runner.Stalled -> Alcotest.fail "Expected requested cancellation"

let closed trace =
  let lifecycle =
    List.map event_tag (D.events trace)
    |> List.filter (fun tag ->
        tag <> "write" && tag <> "stdout" && tag <> "stderr")
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "resource closure order"
    [
      "workspace";
      "launch";
      "process-closing";
      "process-closed";
      "after-run";
      "lease-closing";
      "lease-released";
    ]
    lifecycle

let turn_handler counter peer call =
  incr counter;
  let id = "runner-turn-" ^ string_of_int !counter in
  D.reply peer call (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ]);
  D.completed peer ~id ~status:"completed" ()

let calls trace method_name =
  List.filter
    (fun call -> D.method_name call = Some method_name)
    (D.writes trace)

let prompt call =
  match Json.view (D.field "params" call |> D.field "input") with
  | Json.Array [ input ] ->
      Alcotest.check Alcotest.string "text-only prompt" "text"
        (D.field "type" input |> D.text_value);
      D.field "text" input |> D.text_value
  | Json.Array ([] | _ :: _ :: _)
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _ ->
      Alcotest.fail "Expected one text input"

let continuation_and_cap () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let turns = ref 0 in
      let process = D.process trace (D.server ~turn:(turn_handler turns)) in
      let runner = Runner.create ~process ~version:D.version in
      let notices = ref [] in
      let refreshed = ref [] in
      let emit progress = notices := progress :: !notices in
      let refresh ~turn =
        (match !notices with
        | last :: _ ->
            Alcotest.check Alcotest.string "success precedes fenced refresh"
              "turn-completed" (notice_tag last)
        | [] -> Alcotest.fail "Refresh preceded progress");
        refreshed := Turn_id.text turn :: !refreshed;
        Ok (Agent_runner.Continue (D.issue ~title:"Refreshed title" ()))
      in
      let original = request ~max_turns:2 () in
      let completed =
        Runner.run runner ~clock ~workspace:(D.workspace trace) ~interrupt ~emit
          ~refresh original
      in
      success completed;
      closed trace;
      Alcotest.check Alcotest.bool "original issue completion witness" true
        (Issue_id.equal
           (Runner.completed_issue completed)
           (Issue.id (Runner.issue original)));
      Alcotest.check Alcotest.bool "original run completion witness" true
        (Run_id.equal (Runner.completed_run completed) (Runner.run_id original));
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "every success refreshes once"
        [ "runner-turn-1"; "runner-turn-2" ]
        (List.rev !refreshed);
      let ordered = List.rev !notices in
      List.iteri
        (fun index progress ->
          Alcotest.check Alcotest.string "one causal progress sequence"
            (string_of_int (index + 1))
            (Runner.sequence progress |> Positive_count.count |> Count.decimal))
        ordered;
      let tags = List.map notice_tag ordered in
      let rec prefix expected actual =
        match (expected, actual) with
        | [], _ -> ()
        | before :: rest, observed :: remaining ->
            Alcotest.check Alcotest.string "preparation order" before observed;
            prefix rest remaining
        | _ :: _, [] -> Alcotest.fail "Missing preparation progress"
      in
      prefix
        [
          "preparing";
          "workspace-ready";
          "rendering";
          "starting";
          "session-started";
        ]
        tags;
      Alcotest.check Alcotest.int "one success barrier per turn" 2
        (List.length (List.filter (( = ) "turn-completed") tags));
      Alcotest.check Alcotest.int "frozen cap stops further turns" 2 !turns;
      let starts = calls trace "turn/start" in
      match starts with
      | [ first; second ] ->
          Alcotest.check Alcotest.string "first full prompt"
            "FULL-TASK-ONLY SYM-9: Scoped agent fixture" (prompt first);
          let guidance = prompt second in
          Alcotest.check Alcotest.bool "continuation does not resend task" true
            (guidance <> ""
            && not (String.starts_with ~prefix:"FULL-TASK-ONLY" guidance));
          List.iter
            (fun call ->
              Alcotest.check Alcotest.string "same thread" "thread-9"
                (D.field "params" call |> D.field "threadId" |> D.text_value))
            starts
      | [] | [ _ ] | _ :: _ :: _ :: _ ->
          Alcotest.fail "Expected exactly two turns")

let completion_after_closure () =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let trace = D.trace () in
          let process_close = D.gate () in
          let after_run = D.gate () in
          let lease_release = D.gate () in
          let _, clock = D.clock () in
          let interrupt, _ = Eio.Promise.create () in
          let turns = ref 0 in
          let process =
            D.process ~close:process_close trace
              (D.server ~turn:(turn_handler turns))
          in
          let runner = Runner.create ~process ~version:D.version in
          let result, resolver = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              Eio.Promise.resolve resolver
                (Runner.run runner ~clock
                   ~workspace:
                     (D.workspace ~after_run ~release:lease_release trace)
                   ~interrupt
                   ~emit:(fun _ -> ())
                   ~refresh:(fun ~turn:_ -> Ok Agent_runner.Stop)
                   (request ())));
          let pending label =
            Alcotest.check Alcotest.bool label true
              (Eio.Promise.peek result = None)
          in
          Fun.protect
            ~finally:(fun () ->
              List.iter D.release [ process_close; after_run; lease_release ])
            (fun () ->
              D.wait_event trace (fun event ->
                  event_tag event = "process-closing");
              pending "remote success is not process closure";
              D.release process_close;
              D.wait_event trace (fun event -> event_tag event = "after-run");
              pending "after_run is part of completion";
              D.release after_run;
              D.wait_event trace (fun event ->
                  event_tag event = "lease-closing");
              pending "lease release is part of completion";
              D.release lease_release;
              success (Eio.Promise.await result);
              closed trace)))

let pre_resolved_interrupt () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, resolver = Eio.Promise.create () in
      Eio.Promise.resolve resolver
        (Agent_runner.Cancel Agent_runner.Reconciliation);
      let turns = ref 0 in
      let process = D.process trace (D.server ~turn:(turn_handler turns)) in
      let runner = Runner.create ~process ~version:D.version in
      let refreshed = ref 0 in
      let completed =
        Runner.run runner ~clock ~workspace:(D.workspace trace) ~interrupt
          ~emit:(fun _ -> ())
          ~refresh:(fun ~turn:_ ->
            incr refreshed;
            Ok Agent_runner.Stop)
          (request ())
      in
      canceled Agent_runner.Reconciliation completed;
      Alcotest.check Alcotest.int "no resource or hook acquisition" 0
        (List.length (D.events trace));
      Alcotest.check Alcotest.int "no refresh after prior cancellation" 0
        !refreshed)

let interrupt_after_preparing cause () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, resolver = Eio.Promise.create () in
      let turns = ref 0 in
      let process = D.process trace (D.server ~turn:(turn_handler turns)) in
      let runner = Runner.create ~process ~version:D.version in
      let notices = ref [] in
      let refreshed = ref 0 in
      let emit progress =
        notices := notice_tag progress :: !notices;
        match Runner.notice progress with
        | Runner.Preparing ->
            (* Returning without yielding leaves the watcher unscheduled. *)
            Eio.Promise.resolve resolver cause
        | Runner.Workspace_ready _
        | Runner.Rendering
        | Runner.Starting
        | Runner.Protocol _ -> ()
      in
      let completed =
        Runner.run runner ~clock ~workspace:(D.workspace trace) ~interrupt ~emit
          ~refresh:(fun ~turn:_ ->
            incr refreshed;
            Ok Agent_runner.Stop)
          (request ())
      in
      (match (cause, Runner.outcome completed) with
      | ( Agent_runner.Cancel reason,
          Agent_runner.Canceled { reason = actual; remote_error } ) ->
          Alcotest.check Alcotest.bool "original cancellation cause" true
            (actual = reason);
          Alcotest.check Alcotest.bool "no remote error before acquisition" true
            (Option.is_none remote_error)
      | Agent_runner.Stall, Agent_runner.Stalled -> ()
      | ( (Agent_runner.Cancel _ | Agent_runner.Stall),
          ( Agent_runner.Succeeded
          | Agent_runner.Failed _
          | Agent_runner.Timed_out _
          | Agent_runner.Stalled
          | Agent_runner.Canceled _ ) ) ->
          Alcotest.fail "Expected interruption resolved by Preparing receipt");
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "no workspace, hook or process acquisition" []
        (List.map event_tag (D.events trace));
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "receipt interruption stops preparation" [ "preparing" ]
        (List.rev !notices);
      Alcotest.check Alcotest.int "no refresh after receipt interruption" 0
        !refreshed)

let cancellation_in_refresh () =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let trace = D.trace () in
          let _, clock = D.clock () in
          let interrupt, stop = Eio.Promise.create () in
          let entered = D.gate () in
          let blocked = D.gate () in
          let turns = ref 0 in
          let process = D.process trace (D.server ~turn:(turn_handler turns)) in
          let runner = Runner.create ~process ~version:D.version in
          let result, resolver = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              Eio.Promise.resolve resolver
                (Runner.run runner ~clock ~workspace:(D.workspace trace)
                   ~interrupt
                   ~emit:(fun _ -> ())
                   ~refresh:(fun ~turn:_ ->
                     D.release entered;
                     D.await blocked;
                     Ok (Agent_runner.Continue (D.issue ())))
                   (request ())));
          Fun.protect
            ~finally:(fun () -> D.release blocked)
            (fun () ->
              D.await entered;
              Eio.Promise.resolve stop
                (Agent_runner.Cancel Agent_runner.Scope_change);
              canceled Agent_runner.Scope_change (Eio.Promise.await result);
              Alcotest.check Alcotest.int
                "canceled refresh starts no continuation" 1 !turns;
              closed trace)))

let late_usage_refresh () =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let trace = D.trace () in
          let mono, clock = D.clock () in
          let interrupt, _ = Eio.Promise.create () in
          let entered = D.gate () in
          let blocked = D.gate () in
          let reported = D.gate () in
          let returned = ref false in
          let peer = ref None in
          let turns = ref 0 in
          let notices = ref [] in
          let process =
            D.process
              ~on_launch:(fun value -> peer := Some value)
              trace
              (D.server ~turn:(turn_handler turns))
          in
          let runner = Runner.create ~process ~version:D.version in
          let emit progress =
            notices := progress :: !notices;
            match Runner.notice progress with
            | Runner.Protocol
                (Agent_runner.Usage_report { thread; turn; absolute }) ->
                Alcotest.check Alcotest.bool
                  "late usage precedes refresh return" false !returned;
                Alcotest.check Alcotest.string "late usage thread" "thread-9"
                  (Thread_id.text thread);
                Alcotest.check Alcotest.string "late usage completed turn"
                  "runner-turn-1" (Turn_id.text turn);
                Alcotest.check
                  (Alcotest.list Alcotest.string)
                  "late absolute usage" [ "11"; "3"; "14" ]
                  (List.map Count.decimal
                     [
                       Usage.input absolute;
                       Usage.output absolute;
                       Usage.total absolute;
                     ]);
                D.release reported
            | Runner.Preparing
            | Runner.Workspace_ready _
            | Runner.Rendering
            | Runner.Starting
            | Runner.Protocol
                ( Agent_runner.Session_started _
                | Agent_runner.Turn_started _
                | Agent_runner.Turn_completed _
                | Agent_runner.Output _
                | Agent_runner.Rate_limits _
                | Agent_runner.Unsupported_tool _ ) -> ()
          in
          let result, resolver = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              Eio.Promise.resolve resolver
                (Runner.run runner ~clock ~workspace:(D.workspace trace)
                   ~interrupt ~emit
                   ~refresh:(fun ~turn:_ ->
                     D.release entered;
                     D.await blocked;
                     returned := true;
                     Ok Agent_runner.Stop)
                   (request ())));
          Fun.protect
            ~finally:(fun () -> D.release blocked)
            (fun () ->
              D.await entered;
              D.advance mono 100;
              let active =
                match !peer with
                | Some peer -> peer
                | None -> Alcotest.fail "No scoped peer"
              in
              D.notify active "thread/tokenUsage/updated"
                (D.json
                   {|{"threadId":"thread-9","turnId":"runner-turn-1","tokenUsage":{"total":{"inputTokens":11,"cachedInputTokens":0,"outputTokens":3,"reasoningOutputTokens":0,"totalTokens":14},"last":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2}}}|});
              D.await reported;
              Alcotest.check Alcotest.bool
                "refresh still owns continuation decision" true
                (Eio.Promise.peek result = None);
              Alcotest.check Alcotest.int "late usage starts no continuation" 1
                !turns;
              let protocol =
                List.map notice_tag (List.rev !notices)
                |> List.filter (fun tag ->
                    tag = "turn-completed" || tag = "usage")
              in
              Alcotest.check
                (Alcotest.list Alcotest.string)
                "late usage follows success barrier"
                [ "turn-completed"; "usage" ]
                protocol;
              D.release blocked;
              success (Eio.Promise.await result);
              closed trace)))

let defects_drain () =
  List.iter
    (fun marker ->
      Eio_mock.Backend.run (fun () ->
          let trace = D.trace () in
          let _, clock = D.clock () in
          let interrupt, _ = Eio.Promise.create () in
          let turns = ref 0 in
          let process = D.process trace (D.server ~turn:(turn_handler turns)) in
          let runner = Runner.create ~process ~version:D.version in
          let caught =
            try
              ignore
                (Runner.run runner ~clock ~workspace:(D.workspace trace)
                   ~interrupt
                   ~emit:(fun _ -> ())
                   ~refresh:(fun ~turn:_ -> raise marker)
                   (request ()));
              false
            with error -> error == marker
          in
          Alcotest.check Alcotest.bool "same unrelated exception after drain"
            true caught;
          closed trace))
    [
      Failure "refresh defect";
      Eio.Cancel.Cancelled (Failure "unrequested host stop");
    ]

type template_fault = Syntax_fault | Value_fault

let failed_prompt = function
  | Syntax_fault -> "{{ unclosed"
  | Value_fault -> "{{ issue.absent }}"

let failed_template fault () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let turns = ref 0 in
      let process = D.process trace (D.server ~turn:(turn_handler turns)) in
      let runner = Runner.create ~process ~version:D.version in
      let completed =
        Runner.run runner ~clock ~workspace:(D.workspace trace) ~interrupt
          ~emit:(fun _ -> ())
          ~refresh:(fun ~turn:_ -> Ok Agent_runner.Stop)
          (request ~prompt:(failed_prompt fault) ())
      in
      (match (fault, Runner.outcome completed) with
      | ( Syntax_fault,
          Agent_runner.Failed
            (Agent_runner.Template_error (Template.Parse_error _)) )
      | ( Value_fault,
          Agent_runner.Failed
            (Agent_runner.Template_error (Template.Render_error _)) ) -> ()
      | ( (Syntax_fault | Value_fault),
          Agent_runner.Failed
            (Agent_runner.Template_error
               (Template.Parse_error _ | Template.Render_error _)) ) ->
          Alcotest.fail "Expected the selected template failure stage"
      | ( (Syntax_fault | Value_fault),
          ( Agent_runner.Failed
              ( Agent_runner.Codex_not_found _
              | Agent_runner.Invalid_workspace_cwd _
              | Agent_runner.Port_exit _
              | Agent_runner.Response_error _
              | Agent_runner.Turn_failed _
              | Agent_runner.Turn_input_required _
              | Agent_runner.Workspace_error _
              | Agent_runner.Tracker_error _ )
          | Agent_runner.Succeeded
          | Agent_runner.Timed_out _
          | Agent_runner.Stalled
          | Agent_runner.Canceled _ ) ) ->
          Alcotest.fail "Expected template failure");
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "template failure closes acquired workspace"
        [ "workspace"; "after-run"; "lease-closing"; "lease-released" ]
        (List.map event_tag (D.events trace)))

type template_receipt = Workspace_receipt | Render_receipt

let interrupt_template receipt cause fault () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, resolver = Eio.Promise.create () in
      let turns = ref 0 in
      let process = D.process trace (D.server ~turn:(turn_handler turns)) in
      let runner = Runner.create ~process ~version:D.version in
      let notices = ref [] in
      let refreshed = ref 0 in
      let emit progress =
        notices := notice_tag progress :: !notices;
        match Runner.notice progress with
        | Runner.Workspace_ready _ -> (
            match receipt with
            | Workspace_receipt ->
                (* The synchronous receipt beats the unscheduled watcher. *)
                Eio.Promise.resolve resolver cause
            | Render_receipt -> ())
        | Runner.Rendering -> (
            match receipt with
            | Render_receipt -> Eio.Promise.resolve resolver cause
            | Workspace_receipt -> ())
        | Runner.Preparing | Runner.Starting | Runner.Protocol _ -> ()
      in
      let completed =
        Runner.run runner ~clock ~workspace:(D.workspace trace) ~interrupt ~emit
          ~refresh:(fun ~turn:_ ->
            incr refreshed;
            Ok Agent_runner.Stop)
          (request ~prompt:(failed_prompt fault) ())
      in
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "receipt interruption closes acquired workspace without process"
        [ "workspace"; "after-run"; "lease-closing"; "lease-released" ]
        (List.map event_tag (D.events trace));
      Alcotest.check Alcotest.int "receipt interruption reaches no refresh" 0
        !refreshed;
      (match (cause, Runner.outcome completed) with
      | ( Agent_runner.Cancel reason,
          Agent_runner.Canceled { reason = actual; remote_error } ) ->
          Alcotest.check Alcotest.bool "original receipt cancellation cause"
            true (actual = reason);
          Alcotest.check Alcotest.bool "no remote error before process launch"
            true
            (Option.is_none remote_error)
      | Agent_runner.Stall, Agent_runner.Stalled -> ()
      | ( (Agent_runner.Cancel _ | Agent_runner.Stall),
          ( Agent_runner.Succeeded
          | Agent_runner.Failed _
          | Agent_runner.Timed_out _
          | Agent_runner.Stalled
          | Agent_runner.Canceled _ ) ) ->
          Alcotest.fail
            "Template failure masked a resolved receipt interruption");
      let expected =
        match receipt with
        | Workspace_receipt -> [ "preparing"; "workspace-ready" ]
        | Render_receipt -> [ "preparing"; "workspace-ready"; "rendering" ]
      in
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "receipt interruption stops later preparation notices" expected
        (List.rev !notices))

type primary_case =
  | Remote_failure
  | Tracker_failure
  | Local_cancel
  | Template_failure
  | Successful

type cleanup_case = Process_cleanup | Workspace_cleanup of D.cleanup_stage

let cleanup_primary cleanup primary () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, stop = Eio.Promise.create () in
      let fault = Failure "secondary cleanup defect" in
      let diagnostic =
        Diagnostic.make ~site:(Diagnostic.Host "primary-refresh")
          ~message:"primary tracker failure"
          ~remedy:"Retry the correlated refresh"
      in
      let tracker =
        Tracker_error.make Tracker_error.Tracker_request diagnostic
      in
      let remote =
        D.json
          {|{"message":"primary remote failure","codexErrorInfo":"sandboxError"}|}
      in
      let handler peer call =
        match D.method_name call with
        | Some "turn/start" -> (
            D.reply peer call
              (D.obj
                 [ ("turn", D.turn ~id:"primary-turn" ~status:"inProgress" ()) ]);
            match primary with
            | Remote_failure ->
                D.completed peer ~id:"primary-turn" ~status:"failed"
                  ~error:remote ()
            | Local_cancel -> ()
            | Tracker_failure | Template_failure | Successful ->
                D.completed peer ~id:"primary-turn" ~status:"completed" ())
        | Some "turn/interrupt" ->
            D.reply peer call (D.json "{}");
            D.completed peer ~id:"primary-turn" ~status:"interrupted"
              ~error:remote ()
        | Some _ | None -> D.server ~turn:(turn_handler (ref 0)) peer call
      in
      let process =
        match cleanup with
        | Process_cleanup -> D.process ~fault trace handler
        | Workspace_cleanup _ -> D.process trace handler
      in
      let manager =
        match cleanup with
        | Process_cleanup -> D.workspace trace
        | Workspace_cleanup stage -> D.workspace ~fault:(stage, fault) trace
      in
      let runner = Runner.create ~process ~version:D.version in
      let emit progress =
        match (primary, Runner.notice progress) with
        | Local_cancel, Runner.Protocol (Agent_runner.Session_started _) ->
            Eio.Promise.resolve stop
              (Agent_runner.Cancel Agent_runner.Host_shutdown)
        | ( ( Remote_failure
            | Tracker_failure
            | Local_cancel
            | Template_failure
            | Successful ),
            ( Runner.Preparing
            | Runner.Workspace_ready _
            | Runner.Rendering
            | Runner.Starting
            | Runner.Protocol
                ( Agent_runner.Session_started _
                | Agent_runner.Turn_started _
                | Agent_runner.Turn_completed _
                | Agent_runner.Output _
                | Agent_runner.Usage_report _
                | Agent_runner.Rate_limits _
                | Agent_runner.Unsupported_tool _ ) ) ) -> ()
      in
      let prompt =
        match primary with
        | Template_failure -> "{{ unclosed"
        | Remote_failure | Tracker_failure | Local_cancel | Successful ->
            "Primary task"
      in
      let actual =
        try
          Ok
            (Runner.run runner ~clock ~workspace:manager ~interrupt ~emit
               ~refresh:(fun ~turn:_ ->
                 match primary with
                 | Tracker_failure -> Error tracker
                 | Remote_failure | Local_cancel | Template_failure | Successful
                   -> Ok Agent_runner.Stop)
               (request ~prompt ()))
        with error -> Error error
      in
      (match primary with
      | Template_failure ->
          Alcotest.check
            (Alcotest.list Alcotest.string)
            "template failure still releases lease"
            [ "workspace"; "after-run"; "lease-closing"; "lease-released" ]
            (List.map event_tag (D.events trace))
      | Remote_failure | Tracker_failure | Local_cancel | Successful ->
          closed trace);
      match (primary, actual) with
      | Successful, Error error ->
          Alcotest.check Alcotest.bool
            "successful primary exposes the cleanup defect" true (error == fault)
      | ( (Remote_failure | Tracker_failure | Local_cancel | Template_failure),
          Error _ ) ->
          Alcotest.fail "Cleanup defect replaced the primary outcome"
      | Successful, Ok _ ->
          Alcotest.fail "Successful primary hid the cleanup defect"
      | ( (Remote_failure | Tracker_failure | Local_cancel | Template_failure),
          Ok completed ) -> (
          match (primary, Runner.outcome completed) with
          | ( Remote_failure,
              Agent_runner.Failed (Agent_runner.Turn_failed diagnostic) ) ->
              Alcotest.check Alcotest.bool
                "remote failure keeps protocol diagnostic" true
                (Diagnostic.site diagnostic
                = Diagnostic.Protocol
                    { method_name = "turn/completed"; request_id = None })
          | ( Tracker_failure,
              Agent_runner.Failed (Agent_runner.Tracker_error actual) ) ->
              Alcotest.check Alcotest.bool
                "tracker failure keeps the original value" true
                (actual == tracker)
          | Local_cancel, Agent_runner.Canceled { reason; remote_error } -> (
              Alcotest.check Alcotest.bool "local cancellation keeps its cause"
                true
                (reason = Agent_runner.Host_shutdown);
              match remote_error with
              | Some diagnostic ->
                  Alcotest.check Alcotest.bool
                    "remote cancellation diagnostic survives cleanup" true
                    (Diagnostic.site diagnostic
                    = Diagnostic.Protocol
                        { method_name = "turn/completed"; request_id = None })
              | None ->
                  Alcotest.fail
                    "Cleanup discarded the remote cancellation diagnostic")
          | ( Template_failure,
              Agent_runner.Failed (Agent_runner.Template_error _) ) -> ()
          | ( ( Remote_failure
              | Tracker_failure
              | Local_cancel
              | Template_failure
              | Successful ),
              ( Agent_runner.Succeeded
              | Agent_runner.Failed
                  ( Agent_runner.Codex_not_found _
                  | Agent_runner.Invalid_workspace_cwd _
                  | Agent_runner.Port_exit _
                  | Agent_runner.Response_error _
                  | Agent_runner.Turn_failed _
                  | Agent_runner.Turn_input_required _
                  | Agent_runner.Template_error _
                  | Agent_runner.Workspace_error _
                  | Agent_runner.Tracker_error _ )
              | Agent_runner.Timed_out _
              | Agent_runner.Stalled
              | Agent_runner.Canceled _ ) ) ->
              Alcotest.fail "Cleanup changed the primary outcome category"))

let process_cleanup_primary () =
  List.iter
    (fun primary -> cleanup_primary Process_cleanup primary ())
    [ Remote_failure; Tracker_failure; Local_cancel ]

let workspace_cleanup_primary () =
  List.iter
    (fun stage ->
      List.iter
        (fun primary -> cleanup_primary (Workspace_cleanup stage) primary ())
        [ Remote_failure; Tracker_failure; Local_cancel; Template_failure ])
    [ D.After_hook; D.Report ]

let successful_cleanup_defect () =
  List.iter
    (fun cleanup -> cleanup_primary cleanup Successful ())
    [
      Process_cleanup;
      Workspace_cleanup D.After_hook;
      Workspace_cleanup D.Report;
    ]

let terminal_bad_suffix decision () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let starts = ref 0 in
      let refreshed = ref 0 in
      let observed = ref [] in
      let turn peer call =
        incr starts;
        let id = "bad-suffix-turn" in
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ]);
        let prefix =
          D.obj
            [
              ("method", D.text "fixture/acceptedBefore");
              ( "params",
                D.obj [ ("threadId", D.text "thread-9"); ("turnId", D.text id) ]
              );
            ]
        in
        let completed =
          D.obj
            [
              ("method", D.text "turn/completed");
              ( "params",
                D.obj
                  [
                    ("threadId", D.text "thread-9");
                    ("turn", D.turn ~id ~status:"completed" ());
                  ] );
            ]
        in
        (* The accepted completion and failed suffix share one transport read. *)
        D.send peer
          (Json.encode prefix ^ "\n" ^ Json.encode completed ^ "\n{broken}\n")
      in
      let runner =
        Runner.create
          ~process:(D.process trace (D.server ~turn))
          ~version:D.version
      in
      let completed =
        Runner.run runner ~clock ~workspace:(D.workspace trace) ~interrupt
          ~emit:(fun progress ->
            observed := Runner.notice progress :: !observed)
          ~refresh:(fun ~turn:_ ->
            incr refreshed;
            Ok decision)
          (request ~max_turns:2 ())
      in
      closed trace;
      Alcotest.check Alcotest.bool "accepted prefix stays observable" true
        (List.exists
           (function
             | Runner.Protocol (Agent_runner.Output { event_name; _ }) ->
                 event_name = "fixture/acceptedBefore"
             | Runner.Preparing
             | Runner.Workspace_ready _
             | Runner.Rendering
             | Runner.Starting
             | Runner.Protocol
                 ( Agent_runner.Session_started _
                 | Agent_runner.Turn_started _
                 | Agent_runner.Turn_completed _
                 | Agent_runner.Usage_report _
                 | Agent_runner.Rate_limits _
                 | Agent_runner.Unsupported_tool _ ) -> false)
           !observed);
      (match Runner.outcome completed with
      | Agent_runner.Failed (Agent_runner.Response_error _) -> ()
      | Agent_runner.Failed
          ( Agent_runner.Codex_not_found _
          | Agent_runner.Invalid_workspace_cwd _
          | Agent_runner.Port_exit _
          | Agent_runner.Turn_failed _
          | Agent_runner.Turn_input_required _
          | Agent_runner.Template_error _
          | Agent_runner.Workspace_error _
          | Agent_runner.Tracker_error _ )
      | Agent_runner.Succeeded
      | Agent_runner.Timed_out _
      | Agent_runner.Stalled
      | Agent_runner.Canceled _ ->
          Alcotest.fail
            "Known framing failure was hidden by a successful terminal");
      Alcotest.check Alcotest.int "failed frame starts no continuation" 1
        !starts;
      Alcotest.check Alcotest.int "failed frame reaches no refresh callback" 0
        !refreshed)

module Refresh_clock = struct
  module Pure = Clock_posix.Pure

  type fiber = Eio.Private.Fiber_context.t
  type gate_mode = Before_read | After_packet

  type t = {
    source : Clock_posix.t;
    reader : D.gate;
    watcher : D.gate;
    fault_returned : D.gate;
    mutable owner : fiber option;
    mutable pumps : fiber list;
    mutable consumer : (fiber * Eio.Cancel.t) option;
    mutable held : fiber option;
    mutable mode : gate_mode;
    mutable armed : bool;
    mutable canceled : bool;
    mutable on_cancel : unit -> (unit, Diagnostic.t) result;
  }

  let context () = Effect.perform Eio.Private.Effects.Get_context

  let create source =
    {
      source;
      reader = D.gate ();
      watcher = D.gate ();
      fault_returned = D.gate ();
      owner = None;
      pumps = [];
      consumer = None;
      held = None;
      mode = Before_read;
      armed = false;
      canceled = false;
      on_cancel = (fun () -> Ok ());
    }

  let own t = t.owner <- Some (context ())
  let pump t = t.pumps <- context () :: t.pumps

  let arm t mode on_cancel =
    t.mode <- mode;
    t.on_cancel <- on_cancel;
    t.armed <- true

  let parent t =
    match t.consumer with
    | Some (_, parent) -> parent
    | None -> Alcotest.fail "No gated packet consumer"

  let protected t fiber =
    Option.fold ~none:false ~some:(fun owner -> owner == fiber) t.owner
    || List.exists (fun pump -> pump == fiber) t.pumps

  let hold t fiber =
    let reader = Option.is_none t.held in
    if reader then t.held <- Some fiber;
    D.release (if reader then t.reader else t.watcher);
    try Eio.Fiber.await_cancel ()
    with Eio.Cancel.Cancelled _ ->
      Eio.Cancel.protect (fun () ->
          if reader then (
            t.canceled <- true;
            t.armed <- false;
            match t.on_cancel () with
            | Error error -> Error error
            | Ok () ->
                D.await t.fault_returned;
                Clock_posix.now t.source)
          else Clock_posix.now t.source)

  let now t =
    let fiber = context () in
    if (not t.armed) || protected t fiber then Clock_posix.now t.source
    else
      match (t.mode, t.consumer) with
      | Before_read, _ -> hold t fiber
      | After_packet, None ->
          (* The consumer checks time before spawning its packet guard watcher. *)
          t.consumer <-
            Some (fiber, Eio.Private.Fiber_context.cancellation_context fiber);
          Clock_posix.now t.source
      | After_packet, Some (consumer, _) when consumer == fiber ->
          Clock_posix.now t.source
      | After_packet, Some _ -> hold t fiber

  let sample t = Clock_posix.sample t.source
  let sleep_until t = Clock_posix.sleep_until t.source
end

module Refresh_process = struct
  module Path = D.Process.Path

  type error = Diagnostic.t
  type exit = D.Process.exit = Exited of int | Signaled of int
  type t = { source : D.Process.t; clock : Refresh_clock.t }
  type process = { peer : D.Process.process; clock : Refresh_clock.t }

  let with_process (t : t) ~cwd ~env ~command ~on_error use =
    Refresh_clock.own t.clock;
    D.Process.with_process t.source ~cwd ~env ~command ~on_error (fun peer ->
        use { peer; clock = t.clock })

  let read (process : process) =
    Refresh_clock.pump process.clock;
    let result = D.Process.read process.peer in
    (match result with
    | Error _ | Ok None -> D.release process.clock.Refresh_clock.fault_returned
    | Ok (Some _) -> ());
    result

  let stderr (process : process) =
    Refresh_clock.pump process.clock;
    D.Process.stderr process.peer

  let write (process : process) = D.Process.write process.peer
  let await_exit (process : process) = D.Process.await_exit process.peer
end

module Refresh_runner =
  Codex_runner.Make (D.Workspace) (Refresh_process) (Refresh_clock)

type refresh_answer = Stop_refresh | Raise_refresh of exn
type join_error = Read_fault | Read_eof | Truncated_eof | Clock_fault

let outcome_name = function
  | Agent_runner.Succeeded -> "succeeded"
  | Agent_runner.Timed_out _ -> "timed-out"
  | Agent_runner.Stalled -> "stalled"
  | Agent_runner.Canceled _ -> "canceled"
  | Agent_runner.Failed failure -> (
      match failure with
      | Agent_runner.Codex_not_found _ -> "failed/codex-not-found"
      | Agent_runner.Invalid_workspace_cwd _ -> "failed/invalid-cwd"
      | Agent_runner.Port_exit _ -> "failed/port-exit"
      | Agent_runner.Response_error _ -> "failed/response-error"
      | Agent_runner.Turn_failed _ -> "failed/turn"
      | Agent_runner.Turn_input_required _ -> "failed/input-required"
      | Agent_runner.Template_error _ -> "failed/template"
      | Agent_runner.Workspace_error _ -> "failed/workspace"
      | Agent_runner.Tracker_error _ -> "failed/tracker")

let refresh_join_error kind answer () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, source = D.clock () in
      let clock = Refresh_clock.create source in
      let interrupt, _ = Eio.Promise.create () in
      let peer = ref None in
      let starts = ref 0 in
      let returned = ref false in
      let accepted = D.gate () in
      let callback_returned = D.gate () in
      let usage = ref [] in
      let read_error =
        Diagnostic.make ~site:(Diagnostic.Host "refresh-join-read")
          ~message:"Accepted stdout read failure"
          ~remedy:"Restart the scoped test peer"
      in
      let turn active call =
        incr starts;
        let id = "refresh-join-turn" in
        D.reply active call
          (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ]);
        D.notify active "thread/tokenUsage/updated"
          (D.json
             {|{"threadId":"thread-9","turnId":"refresh-join-turn","tokenUsage":{"total":{"inputTokens":11,"cachedInputTokens":0,"outputTokens":3,"reasoningOutputTokens":0,"totalTokens":14},"last":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2}}}|});
        match kind with
        | Truncated_eof ->
            let completed =
              D.obj
                [
                  ("method", D.text "turn/completed");
                  ( "params",
                    D.obj
                      [
                        ("threadId", D.text "thread-9");
                        ("turn", D.turn ~id ~status:"completed" ());
                      ] );
                ]
            in
            (* The success barrier proves feed retained this packet's partial tail. *)
            D.send active (Json.encode completed ^ "\n{\"method\":")
        | Read_fault | Read_eof | Clock_fault ->
            D.completed active ~id ~status:"completed" ()
      in
      let process =
        {
          Refresh_process.source =
            D.process
              ~on_launch:(fun active -> peer := Some active)
              trace (D.server ~turn);
          clock;
        }
      in
      let runner = Refresh_runner.create ~process ~version:D.version in
      let request =
        match
          Refresh_runner.request ~run_id:(D.fresh_run ()) ~issue:(D.issue ())
            ~workspace:(D.reference ()) ~agent:(D.settings ())
            ~prompt_file:D.prompt_file ~prompt_source:"Refresh join task"
            ~attempt:Template.First
        with
        | Ok request -> request
        | Error _ -> Alcotest.fail "Refresh race request was rejected"
      in
      let actual =
        try
          Ok
            (Refresh_runner.run runner ~clock ~workspace:(D.workspace trace)
               ~interrupt
               ~emit:(fun progress ->
                 match Refresh_runner.notice progress with
                 | Refresh_runner.Protocol
                     (Agent_runner.Usage_report { absolute; _ }) ->
                     usage := absolute :: !usage
                 | Refresh_runner.Preparing
                 | Refresh_runner.Workspace_ready _
                 | Refresh_runner.Rendering
                 | Refresh_runner.Starting
                 | Refresh_runner.Protocol
                     ( Agent_runner.Session_started _
                     | Agent_runner.Turn_started _
                     | Agent_runner.Turn_completed _
                     | Agent_runner.Output _
                     | Agent_runner.Rate_limits _
                     | Agent_runner.Unsupported_tool _ ) -> ())
               ~refresh:(fun ~turn:_ ->
                 let active =
                   match !peer with
                   | Some active -> active
                   | None -> Alcotest.fail "No scoped refresh peer"
                 in
                 let mode =
                   match kind with
                   | Read_eof | Truncated_eof -> Refresh_clock.After_packet
                   | Read_fault | Clock_fault -> Refresh_clock.Before_read
                 in
                 Refresh_clock.arm clock mode (fun () ->
                     match kind with
                     | Read_fault ->
                         Alcotest.check Alcotest.bool
                           "refresh answer wins before read cancellation" true
                           !returned;
                         D.read_error active read_error;
                         Ok ()
                     | Read_eof | Truncated_eof ->
                         let parent = Refresh_clock.parent clock in
                         Alcotest.check Alcotest.bool
                           "packet acceptance precedes refresh return" false
                           !returned;
                         Alcotest.check Alcotest.bool
                           "packet guard wins before Answer" true
                           (Option.is_none (Eio.Cancel.get_error parent));
                         D.release accepted;
                         D.await callback_returned;
                         Eio.Fiber.yield ();
                         let answer_won =
                           match Eio.Cancel.get_error parent with
                           | Some (Eio.Cancel.Cancelled _) -> true
                           | None | Some _ -> false
                         in
                         Alcotest.check Alcotest.bool
                           "Answer wins before accepted EOF finishes its join"
                           true answer_won;
                         Ok ()
                     | Clock_fault ->
                         Alcotest.check Alcotest.bool
                           "refresh answer wins before clock cancellation" true
                           !returned;
                         Error read_error);
                 (* Hold the competing guards until the callback can answer. *)
                 D.await clock.Refresh_clock.reader;
                 D.await clock.Refresh_clock.watcher;
                 (match kind with
                 | Read_eof | Truncated_eof ->
                     D.eof active;
                     D.await accepted
                 | Read_fault | Clock_fault -> ());
                 returned := true;
                 D.release callback_returned;
                 match answer with
                 | Stop_refresh -> Ok Agent_runner.Stop
                 | Raise_refresh error -> raise error)
               request)
        with error -> Error error
      in
      closed trace;
      Alcotest.check Alcotest.bool "held operation joined after cancellation"
        true clock.Refresh_clock.canceled;
      Alcotest.check Alcotest.int "refresh starts no continuation" 1 !starts;
      (match !usage with
      | [ absolute ] ->
          Alcotest.check
            (Alcotest.list Alcotest.string)
            "accepted usage survives the read fault" [ "11"; "3"; "14" ]
            (List.map Count.decimal
               [
                 Usage.input absolute;
                 Usage.output absolute;
                 Usage.total absolute;
               ])
      | [] | _ :: _ :: _ -> Alcotest.fail "Accepted usage was lost or repeated");
      match (answer, actual) with
      | Stop_refresh, Ok completed -> (
          let outcome = Refresh_runner.outcome completed in
          match (kind, outcome) with
          | ( (Read_fault | Clock_fault),
              Agent_runner.Failed (Agent_runner.Port_exit actual) ) ->
              Alcotest.check Alcotest.bool "recorded read diagnostic survives"
                true (actual == read_error)
          | Read_eof, Agent_runner.Failed (Agent_runner.Port_exit _)
          | Truncated_eof, Agent_runner.Failed (Agent_runner.Response_error _)
            -> ()
          | ( (Read_fault | Read_eof | Truncated_eof | Clock_fault),
              ( Agent_runner.Failed
                  ( Agent_runner.Codex_not_found _
                  | Agent_runner.Invalid_workspace_cwd _
                  | Agent_runner.Port_exit _
                  | Agent_runner.Response_error _
                  | Agent_runner.Turn_failed _
                  | Agent_runner.Turn_input_required _
                  | Agent_runner.Template_error _
                  | Agent_runner.Workspace_error _
                  | Agent_runner.Tracker_error _ )
              | Agent_runner.Succeeded
              | Agent_runner.Timed_out _
              | Agent_runner.Stalled
              | Agent_runner.Canceled _ ) ) ->
              Alcotest.failf "Losing read error was lost; outcome=%s"
                (outcome_name outcome))
      | Raise_refresh expected, Error actual ->
          Alcotest.check Alcotest.bool "callback defect keeps its identity" true
            (actual == expected)
      | Stop_refresh, Error _ ->
          Alcotest.fail "Expected read failure became an unrelated defect"
      | Raise_refresh _, Ok _ ->
          Alcotest.fail "Read fault replaced callback defect")

let error_wins_refresh_defect () =
  let backtraces = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace backtraces)
    (fun () ->
      Eio_mock.Backend.run (fun () ->
          let trace = D.trace () in
          let _, clock = D.clock () in
          let interrupt, _ = Eio.Promise.create () in
          let peer = ref None in
          let turns = ref 0 in
          let marker = Failure "refresh cancellation finalizer" in
          let original = ref None in
          let runner =
            Runner.create
              ~process:
                (D.process
                   ~on_launch:(fun active -> peer := Some active)
                   trace
                   (D.server ~turn:(turn_handler turns)))
              ~version:D.version
          in
          let actual =
            try
              Ok
                (Runner.run runner ~clock ~workspace:(D.workspace trace)
                   ~interrupt
                   ~emit:(fun _ -> ())
                   ~refresh:(fun ~turn:_ ->
                     let active =
                       match !peer with
                       | Some active -> active
                       | None -> Alcotest.fail "No scoped refresh peer"
                     in
                     try
                       Fun.protect
                         ~finally:(fun () -> raise marker)
                         (fun () ->
                           (* The protocol error wins while refresh remains blocked. *)
                           D.send active "{late-malformed}\n";
                           Eio.Fiber.await_cancel ())
                     with error ->
                       let backtrace = Printexc.get_raw_backtrace () in
                       original := Some (error, backtrace);
                       Printexc.raise_with_backtrace error backtrace)
                   (request ()))
            with error -> Error (error, Printexc.get_raw_backtrace ())
          in
          closed trace;
          Alcotest.check Alcotest.int "failed refresh starts no continuation" 1
            !turns;
          let expected, origin =
            match !original with
            | Some captured -> captured
            | None ->
                Alcotest.fail "Refresh finalizer did not finish during join"
          in
          (match expected with
          | Fun.Finally_raised inner ->
              Alcotest.check Alcotest.bool "ordinary finalizer marker survives"
                true (inner == marker)
          | _ -> Alcotest.fail "Refresh lost its original finalizer exception");
          match actual with
          | Ok _ ->
              Alcotest.fail "Joined refresh defect became a protocol outcome"
          | Error (error, backtrace) ->
              Alcotest.check Alcotest.bool "joined callback exception identity"
                true (error == expected);
              let before = Printexc.raw_backtrace_entries origin in
              let after = Printexc.raw_backtrace_entries backtrace in
              let length = Array.length before in
              Alcotest.check Alcotest.bool "captured callback has a backtrace"
                true (length > 0);
              Alcotest.check Alcotest.bool
                "joined callback backtrace keeps origin" true
                (Array.length after >= length
                && Array.sub after 0 length = before)))

let suite () =
  let example = Alcotest.test_case in
  ( "closed Codex runner",
    [
      example "ordered progress, success barrier, refresh and frozen turn cap"
        `Quick continuation_and_cap;
      example "completion follows process, after_run and lease release" `Quick
        completion_after_closure;
      example "prior cancellation acquires no scope" `Quick
        pre_resolved_interrupt;
      example "Preparing receipt cancellation acquires no scope" `Quick
        (interrupt_after_preparing
           (Agent_runner.Cancel Agent_runner.Reconciliation));
      example "Preparing receipt stall acquires no scope" `Quick
        (interrupt_after_preparing Agent_runner.Stall);
      example "cancellation wakes a blocked fenced refresh" `Quick
        cancellation_in_refresh;
      example "late completed-turn usage reaches progress during fenced refresh"
        `Quick late_usage_refresh;
      example "unrelated defects and host cancellation drain unchanged" `Quick
        defects_drain;
      example "template failure closes workspace without launching process"
        `Quick
        (failed_template Syntax_fault);
      example
        "process cleanup defects preserve primary failure and cancellation"
        `Quick process_cleanup_primary;
      example "after_run and reporting defects preserve non-success primary"
        `Quick workspace_cleanup_primary;
      example "successful primary exposes cleanup defects after closure" `Quick
        successful_cleanup_defect;
      example
        "completed terminal cannot hide malformed suffix with refresh Stop"
        `Quick
        (terminal_bad_suffix Agent_runner.Stop);
      example
        "completed terminal cannot hide malformed suffix with refresh Continue"
        `Quick
        (terminal_bad_suffix (Agent_runner.Continue (D.issue ())));
      example "refresh Stop observes read fault recorded during losing join"
        `Quick
        (refresh_join_error Read_fault Stop_refresh);
      example "refresh defect survives read fault recorded during losing join"
        `Quick
        (refresh_join_error Read_fault
           (Raise_refresh (Failure "refresh join defect")));
      example "refresh Stop observes EOF accepted during losing join" `Quick
        (refresh_join_error Read_eof Stop_refresh);
      example "refresh Stop observes truncated EOF accepted during losing join"
        `Quick
        (refresh_join_error Truncated_eof Stop_refresh);
      example "refresh Stop observes expected clock failure during losing join"
        `Quick
        (refresh_join_error Clock_fault Stop_refresh);
      example "Error-winning protocol join preserves refresh finalizer defect"
        `Quick error_wins_refresh_defect;
      example "render failure closes workspace without interruption" `Quick
        (failed_template Value_fault);
      example "Workspace_ready Cancel precedes compile failure" `Quick
        (interrupt_template Workspace_receipt
           (Agent_runner.Cancel Agent_runner.Reconciliation) Syntax_fault);
      example "Workspace_ready Stall precedes compile failure" `Quick
        (interrupt_template Workspace_receipt Agent_runner.Stall Syntax_fault);
      example "Workspace_ready Cancel precedes render failure" `Quick
        (interrupt_template Workspace_receipt
           (Agent_runner.Cancel Agent_runner.Reconciliation) Value_fault);
      example "Workspace_ready Stall precedes render failure" `Quick
        (interrupt_template Workspace_receipt Agent_runner.Stall Value_fault);
      example "Rendering Cancel precedes compile failure" `Quick
        (interrupt_template Render_receipt
           (Agent_runner.Cancel Agent_runner.Reconciliation) Syntax_fault);
      example "Rendering Stall precedes compile failure" `Quick
        (interrupt_template Render_receipt Agent_runner.Stall Syntax_fault);
      example "Rendering Cancel precedes render failure" `Quick
        (interrupt_template Render_receipt
           (Agent_runner.Cancel Agent_runner.Reconciliation) Value_fault);
      example "Rendering Stall precedes render failure" `Quick
        (interrupt_template Render_receipt Agent_runner.Stall Value_fault);
    ] )
