module Host = Workspace_host_posix.Make (Clock_posix)
module Manager = Host.Workspace

module Runner : sig
  include
    Service.CLOSED_RUNNER
      with module Issue = Issue
       and module Path = Host.Path
       and type workspace = Manager.Contract.reference
       and type clock = Clock_posix.t
       and type workspace_manager = Manager.t

  val create : process:Host.Process.t -> version:string -> t
end =
  Codex_runner.Make (Manager) (Host.Process) (Clock_posix)

let normal_read_ms = 3000
let normal_turn_ms = 5000
let short_deadline_ms = 150
let hook_deadline_ms = 3000
let fixture_file_limit = 262_144
let initial_prompt = "NATIVE-TASK {{ issue.identifier }}: {{ issue.title }}"

let checked = function
  | Ok value -> value
  | Error error -> Alcotest.fail error

let diagnostic_errors errors =
  Alcotest.fail
    (String.concat "\n"
       (List.map Diagnostic.render (Nonempty_list.to_list errors)))

let workspace_error = function
  | Workspace_manager.Invalid_key error
  | Workspace_manager.Unsafe_path error
  | Workspace_manager.Ownership_conflict error
  | Workspace_manager.Filesystem_error error
  | Workspace_manager.Hook_failed error
  | Workspace_manager.Hook_timeout error -> Diagnostic.render error

let acquired = function
  | Ok value -> value
  | Error error -> Alcotest.fail (workspace_error error)

let read_file file =
  let input = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let length = in_channel_length input in
      if length > fixture_file_limit then
        Alcotest.fail "Native fixture exceeded its file bound";
      really_input_string input length)

let absolute_env name =
  let value =
    match Sys.getenv_opt name with
    | Some value when value <> "" -> value
    | Some _ | None -> Alcotest.fail ("Missing native fixture path: " ^ name)
  in
  checked (Absolute_path.parse value) |> Absolute_path.display

let fixture_command python server =
  "exec " ^ Filename.quote python ^ " " ^ Filename.quote server

let issue ?(title = "Native acceptance") () =
  checked
    (Issue.parse
       {
         Issue.id = "opaque-native-agent";
         identifier = "SYM-native";
         title;
         description = Some "Exercise the closed native attempt";
         priority = None;
         state = "Doing";
         branch_name = None;
         url = None;
         assignee_id = None;
         labels = [];
         blocked_by = [];
         created_at = None;
         updated_at = None;
         dispatchable = Issue.Dispatchable;
         native_ref = None;
       })

type fixture = {
  clock : Clock_posix.t;
  host : Host.t;
  workspace : Host.Contract.reference;
  request : Runner.request;
  path : string;
  hooks : (Workspace_settings.hook * Workspace_hooks.event) list ref;
  reports : Workspace_manager.error list ref;
}

let with_fixture ?(read_ms = normal_read_ms) ?(turn_ms = normal_turn_ms) mode
    run =
  Eio_posix.run (fun capabilities ->
      let python = absolute_env "SYMPHONY_TEST_PYTHON" in
      let server = absolute_env "SYMPHONY_TEST_AGENT_SERVER" in
      let base = Filename.temp_file "symphony-agent-" "" in
      Unix.unlink base;
      Unix.mkdir base 0o700;
      let base = Unix.realpath base in
      let fs = Eio.Stdenv.fs capabilities in
      Fun.protect
        ~finally:(fun () -> Eio.Path.rmtree (Eio.Path.( / ) fs base))
        (fun () ->
          let root = Filename.concat base "workspaces" in
          let public =
            checked
              (Environment.of_bindings
                 ~temp_dir:(checked (Absolute_path.parse base))
                 [
                   ("HOME", base);
                   ("PATH", "/usr/bin:/bin");
                   ("SYMPHONY_AGENT_MODE", mode);
                   ("SYMPHONY_SECRET", "native-private-sentinel");
                 ])
            |> fun env ->
            Environment.public env ~deny:[ "SYMPHONY_SECRET" ] ~secrets:[]
          in
          let child =
            Environment.child public
              ~allow:
                [ "HOME"; "PATH"; "SYMPHONY_AGENT_MODE"; "SYMPHONY_SECRET" ]
          in
          let command = fixture_command python server in
          let config =
            checked
              (Config_value.parse
                 (Yojson.Safe.to_string
                    (`Assoc
                       [
                         ("workspace", `Assoc [ ("root", `String root) ]);
                         ( "hooks",
                           `Assoc
                             [
                               ("after_run", `String (command ^ " --after-run"));
                               ("timeout_ms", `Int hook_deadline_ms);
                             ] );
                         ("agent", `Assoc [ ("max_turns", `Int 3) ]);
                         ( "codex",
                           `Assoc
                             [
                               ( "command",
                                 `String
                                   (command ^ " --mode \"$SYMPHONY_AGENT_MODE\"")
                               );
                               ("read_timeout_ms", `Int read_ms);
                               ("turn_timeout_ms", `Int turn_ms);
                             ] );
                       ])))
          in
          let prompt_file =
            checked
              (Workflow_path.resolve
                 ~base:(checked (Absolute_path.parse base))
                 "WORKFLOW.md")
          in
          let settings =
            match
              Workspace_settings.parse ~env:public ~workflow_file:prompt_file
                config
            with
            | Ok value -> value
            | Error errors -> diagnostic_errors errors
          in
          let agent =
            match Agent_settings.parse ~env:public config with
            | Ok value -> value
            | Error errors -> diagnostic_errors errors
          in
          let original_issue = issue () in
          let workspace =
            acquired
              (Host.Contract.reference ~settings ~env:child
                 ~scope:(checked (Tracker_scope.parse "native-agent-test"))
                 ~issue_id:(Issue.id original_issue)
                 ~identifier:(Issue.identifier original_issue))
          in
          let path =
            Filename.concat root
              (Workspace_key.text (Host.Contract.key workspace))
          in
          let run_id = fst (Run_id.Allocator.fresh Run_id.Allocator.empty) in
          let request =
            acquired
              (Runner.request ~run_id ~issue:original_issue ~workspace ~agent
                 ~prompt_file ~prompt_source:initial_prompt
                 ~attempt:Template.First)
          in
          let clock =
            Clock_posix.create
              ~mono:(Eio.Stdenv.mono_clock capabilities)
              ~wall:(Eio.Stdenv.clock capabilities)
          in
          let hooks = ref [] and reports = ref [] in
          let host =
            Host.create ~fs ~clock
              ~emit:(fun _ phase event -> hooks := (phase, event) :: !hooks)
              ~report:(fun error -> reports := error :: !reports)
          in
          run { clock; host; workspace; request; path; hooks; reports }))

let artifact fixture name = Filename.concat fixture.path name

let child_reaped fixture =
  let pid =
    int_of_string (String.trim (read_file (artifact fixture "agent.pid")))
  in
  try
    Unix.kill pid 0;
    Alcotest.fail "Native child remains live or unreaped after completion"
  with Unix.Unix_error (Unix.ESRCH, _, _) -> ()

let closed fixture completed =
  Alcotest.check Alcotest.bool "original issue witness" true
    (Issue_id.equal
       (Runner.completed_issue completed)
       (Issue.id (Runner.issue fixture.request)));
  Alcotest.check Alcotest.bool "original run witness" true
    (Run_id.equal
       (Runner.completed_run completed)
       (Runner.run_id fixture.request));
  child_reaped fixture;
  Alcotest.check Alcotest.bool "after_run completed before return" true
    (Sys.file_exists (artifact fixture "after-run"));
  let after_hooks =
    List.filter
      (fun (phase, _) -> phase = Workspace_settings.After_run)
      (List.rev !(fixture.hooks))
  in
  let hook_status (_, event) =
    match event with
    | Workspace_hooks.Started -> "started"
    | Workspace_hooks.Finished Workspace_hooks.Cancelled -> "canceled"
    | Workspace_hooks.Finished (Workspace_hooks.Completed (Ok ())) -> "ok"
    | Workspace_hooks.Finished (Workspace_hooks.Completed (Error _)) -> "failed"
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "native after_run finishes once" [ "started"; "ok" ]
    (List.map hook_status after_hooks);
  Alcotest.check Alcotest.int "no ignored native cleanup errors" 0
    (List.length !(fixture.reports));
  Alcotest.check Alcotest.bool "peer accepted protocol and environment" false
    (Sys.file_exists (artifact fixture "protocol-errors.txt"));
  let manager = Host.workspace fixture.host in
  (* Inspection requires the same ownership lock, so it proves lease release. *)
  (match acquired (Manager.inspect manager fixture.workspace) with
  | Some _ -> ()
  | None -> Alcotest.fail "Attempt unexpectedly removed its workspace");
  let request_id =
    fst (Request_id.Allocator.fresh Request_id.Allocator.empty)
  in
  acquired
    (Manager.cleanup manager
       { Host.Contract.request_id; workspace = fixture.workspace });
  Alcotest.check Alcotest.bool "released workspace remains removable" true
    (acquired (Manager.inspect manager fixture.workspace) = None)

let wire fixture =
  String.split_on_char '\n' (read_file (artifact fixture "agent-wire.jsonl"))
  |> List.filter (fun line -> line <> "")
  |> List.map (fun line -> checked (Json.parse line))

let field name value =
  match Json.view value with
  | Json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> value
      | None -> Alcotest.fail ("Missing native wire field: " ^ name))
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "Native wire value is not an object"

let text value =
  match Json.view value with
  | Json.String value -> value
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      Alcotest.fail "Native wire value is not text"

let method_name value =
  match Json.view value with
  | Json.Object fields -> Option.map text (List.assoc_opt "method" fields)
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "Native wire frame is not an object"

let calls frames method_ =
  List.filter (fun frame -> method_name frame = Some method_) frames

let prompt frame =
  match Json.view (field "input" (field "params" frame)) with
  | Json.Array [ input ] -> text (field "text" input)
  | Json.Array ([] | _ :: _ :: _)
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _ ->
      Alcotest.fail "Expected one native text input"

let expect_success completed =
  match Runner.outcome completed with
  | Agent_runner.Succeeded -> ()
  | Agent_runner.Failed _
  | Agent_runner.Timed_out _
  | Agent_runner.Stalled
  | Agent_runner.Canceled _ ->
      Alcotest.fail "Native continuation attempt failed"

let normal () =
  with_fixture "normal" (fun fixture ->
      let interrupt, _ = Eio.Promise.create () in
      let notices = ref [] and refreshed = ref [] and usages = ref [] in
      let emit progress =
        notices := progress :: !notices;
        match Runner.notice progress with
        | Runner.Protocol (Agent_runner.Usage_report { thread; turn; absolute })
          ->
            usages :=
              (Thread_id.text thread, Turn_id.text turn, absolute) :: !usages
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
      let refresh ~turn =
        (match !notices with
        | last :: _ -> (
            match Runner.notice last with
            | Runner.Protocol (Agent_runner.Turn_completed _) -> ()
            | Runner.Preparing
            | Runner.Workspace_ready _
            | Runner.Rendering
            | Runner.Starting
            | Runner.Protocol
                ( Agent_runner.Session_started _
                | Agent_runner.Turn_started _
                | Agent_runner.Usage_report _
                | Agent_runner.Output _
                | Agent_runner.Rate_limits _
                | Agent_runner.Unsupported_tool _ ) ->
                Alcotest.fail "Native refresh preceded the turn success barrier"
            )
        | [] -> Alcotest.fail "Native refresh preceded progress");
        refreshed := Turn_id.text turn :: !refreshed;
        Ok (Agent_runner.Continue (issue ~title:"Refreshed native issue" ()))
      in
      let runner =
        Runner.create
          ~process:(Host.process fixture.host)
          ~version:"native-test"
      in
      let completed =
        Runner.run runner ~clock:fixture.clock
          ~workspace:(Host.workspace fixture.host)
          ~interrupt ~emit ~refresh fixture.request
      in
      expect_success completed;
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "two native continuations"
        [ "native-turn-1"; "native-turn-2"; "native-turn-3" ]
        (List.rev !refreshed);
      List.iteri
        (fun index progress ->
          Alcotest.check Alcotest.string "native causal progress"
            (string_of_int (index + 1))
            (Runner.sequence progress |> Positive_count.count |> Count.decimal))
        (List.rev !notices);
      (match !usages with
      | (thread, turn, usage) :: _ ->
          Alcotest.check Alcotest.string "usage thread" "native-thread" thread;
          Alcotest.check Alcotest.string "usage turn" "native-turn-3" turn;
          Alcotest.check Alcotest.string "exact native input above 2^53"
            "9007199254740996"
            (Count.decimal (Usage.input usage));
          Alcotest.check Alcotest.string "exact native output" "6"
            (Count.decimal (Usage.output usage));
          Alcotest.check Alcotest.string "exact native total above 2^53"
            "9007199254741002"
            (Count.decimal (Usage.total usage))
      | [] -> Alcotest.fail "Native usage notification was lost");
      Alcotest.check Alcotest.int "all native usage reports" 3
        (List.length !usages);
      let frames = wire fixture in
      List.iter
        (fun method_ ->
          Alcotest.check Alcotest.int ("one native " ^ method_) 1
            (List.length (calls frames method_)))
        [ "initialize"; "initialized"; "thread/start"; "thread/name/set" ];
      (match calls frames "turn/start" with
      | [ first; second; third ] ->
          Alcotest.check Alcotest.string "full initial native prompt"
            "NATIVE-TASK SYM-native: Native acceptance" (prompt first);
          List.iter
            (fun frame ->
              Alcotest.check Alcotest.bool "continuation is bounded guidance"
                true
                (prompt frame <> ""
                && not (String.starts_with ~prefix:"NATIVE-TASK" (prompt frame))
                ))
            [ second; third ]
      | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ ->
          Alcotest.fail "Native turn cap did not produce exactly three turns");
      Alcotest.check Alcotest.bool "native stderr burst finished" true
        (Sys.file_exists (artifact fixture "stderr-complete"));
      closed fixture completed)

type expected =
  | Input_required
  | Response_error
  | Response_deadline
  | Turn_failed
  | Turn_silence
  | Stalled
  | Canceled

let outcome_tag = function
  | Agent_runner.Succeeded -> "success"
  | Agent_runner.Failed (Agent_runner.Turn_input_required _) -> "input-required"
  | Agent_runner.Failed (Agent_runner.Response_error _) -> "response-error"
  | Agent_runner.Failed (Agent_runner.Turn_failed _) -> "turn-failed"
  | Agent_runner.Failed
      ( Agent_runner.Codex_not_found _
      | Agent_runner.Invalid_workspace_cwd _
      | Agent_runner.Port_exit _
      | Agent_runner.Template_error _
      | Agent_runner.Workspace_error _
      | Agent_runner.Tracker_error _ ) -> "other-failure"
  | Agent_runner.Timed_out (Agent_runner.Response_deadline _) ->
      "response-deadline"
  | Agent_runner.Timed_out (Agent_runner.Turn_silence _) -> "turn-silence"
  | Agent_runner.Stalled -> "stalled"
  | Agent_runner.Canceled
      { reason = Agent_runner.Host_shutdown; remote_error = None } -> "canceled"
  | Agent_runner.Canceled
      {
        reason = Agent_runner.Reconciliation | Agent_runner.Scope_change;
        remote_error = _;
      }
  | Agent_runner.Canceled
      { reason = Agent_runner.Host_shutdown; remote_error = Some _ } ->
      "other-cancellation"

let expected_tag = function
  | Input_required -> "input-required"
  | Response_error -> "response-error"
  | Response_deadline -> "response-deadline"
  | Turn_failed -> "turn-failed"
  | Turn_silence -> "turn-silence"
  | Stalled -> "stalled"
  | Canceled -> "canceled"

let failure mode expected () =
  let read_ms =
    if expected = Response_deadline then short_deadline_ms else normal_read_ms
  in
  let turn_ms =
    if expected = Turn_silence then short_deadline_ms else normal_turn_ms
  in
  with_fixture ~read_ms ~turn_ms mode (fun fixture ->
      let interrupt, resolver = Eio.Promise.create () in
      let emit progress =
        match Runner.notice progress with
        | Runner.Protocol (Agent_runner.Session_started _) -> (
            match expected with
            | Stalled -> Eio.Promise.resolve resolver Agent_runner.Stall
            | Canceled ->
                Eio.Promise.resolve resolver
                  (Agent_runner.Cancel Agent_runner.Host_shutdown)
            | Input_required
            | Response_error
            | Response_deadline
            | Turn_failed
            | Turn_silence -> ())
        | Runner.Preparing
        | Runner.Workspace_ready _
        | Runner.Rendering
        | Runner.Starting
        | Runner.Protocol
            ( Agent_runner.Turn_started _
            | Agent_runner.Turn_completed _
            | Agent_runner.Usage_report _
            | Agent_runner.Output _
            | Agent_runner.Rate_limits _
            | Agent_runner.Unsupported_tool _ ) -> ()
      in
      let refreshes = ref 0 in
      let runner =
        Runner.create
          ~process:(Host.process fixture.host)
          ~version:"native-test"
      in
      let completed =
        Runner.run runner ~clock:fixture.clock
          ~workspace:(Host.workspace fixture.host)
          ~interrupt ~emit
          ~refresh:(fun ~turn:_ ->
            incr refreshes;
            Ok Agent_runner.Stop)
          fixture.request
      in
      Alcotest.check Alcotest.string "native outcome classification"
        (expected_tag expected)
        (outcome_tag (Runner.outcome completed));
      Alcotest.check Alcotest.int "no continuation after native failure" 0
        !refreshes;
      let frames = wire fixture in
      (match expected with
      | Input_required | Stalled | Canceled ->
          Alcotest.check Alcotest.int "bounded native turn interrupt" 1
            (List.length (calls frames "turn/interrupt"))
      | Response_error | Response_deadline | Turn_failed | Turn_silence -> ());
      closed fixture completed)

let tests =
  [
    Alcotest.test_case "native continuations, pipes and exact usage" `Quick
      normal;
    Alcotest.test_case "native input interruption drains terminal" `Quick
      (failure "user-input" Input_required);
    Alcotest.test_case "native malformed frame" `Quick
      (failure "malformed" Response_error);
    Alcotest.test_case "native truncated EOF" `Quick
      (failure "truncated" Response_error);
    Alcotest.test_case "native fixed response deadline" `Quick
      (failure "response-timeout" Response_deadline);
    Alcotest.test_case "native remote failed turn" `Quick
      (failure "failed" Turn_failed);
    Alcotest.test_case "native stdout silence deadline" `Quick
      (failure "stall" Turn_silence);
    Alcotest.test_case "native requested stall drains child" `Quick
      (failure "stall" Stalled);
    Alcotest.test_case "native requested cancellation drains child" `Quick
      (failure "cancel" Canceled);
  ]

let () = Alcotest.run "Native agent" [ ("owned protocol", tests) ]
