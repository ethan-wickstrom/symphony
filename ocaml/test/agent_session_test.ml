module D = Agent_test_driver
module Session = App_server.Make (D.Process) (Clock_posix)

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

let has_event trace name =
  List.exists (fun event -> event_tag event = name) (D.events trace)

let wait trace name = D.wait_event trace (fun event -> event_tag event = name)

let stdout_bytes trace =
  List.fold_left
    (fun bytes -> function
      | D.Read_stdout count -> bytes + count
      | D.Launch _
      | D.Write _
      | D.Read_stderr _
      | D.Process_closing
      | D.Process_closed
      | D.Workspace_acquired
      | D.After_run
      | D.Lease_closing
      | D.Lease_released -> bytes)
    0 (D.events trace)

let result_tag = function
  | Ok ended -> (
      match ended.App_server.outcome with
      | App_server.Completed -> "completed"
      | App_server.Failed _ -> "failed-turn"
      | App_server.Interrupted _ -> "interrupted-turn"
      | App_server.Input_required _ -> "input-required")
  | Error (App_server.Failure _) -> "failure"
  | Error (App_server.Deadline (Agent_runner.Response_deadline _)) ->
      "rpc-deadline"
  | Error (App_server.Deadline (Agent_runner.Turn_silence _)) ->
      "silence-deadline"
  | Error (App_server.Stopped { interrupt; remote_error = _ }) -> (
      match interrupt with
      | Agent_runner.Cancel _ -> "canceled"
      | Agent_runner.Stall -> "stalled")

let check_tag expected result =
  Alcotest.check Alcotest.string "session result" expected (result_tag result)

let call_session ?(settings = D.settings ()) ~trace:_ ~process ~clock ~interrupt
    use =
  D.with_path (fun cwd ->
      Session.with_session ~process ~clock ~interrupt ~cwd ~env:D.environment
        ~settings ~version:D.version ~title:D.title use)

let completed_turn peer call =
  D.reply peer call
    (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
  D.completed peer ~id:"turn-9" ~status:"completed" ()

let run ?(emit = fun _ -> ()) turn =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let process = D.process trace (D.server ~turn) in
      let result =
        call_session ~trace ~process ~clock ~interrupt (fun session ->
            Session.turn session ~prompt:"Work on the issue" ~emit)
      in
      Alcotest.check Alcotest.bool "process is closed before return" true
        (has_event trace "process-closed");
      (result, trace))

let calls trace method_name =
  List.filter
    (fun call -> D.method_name call = Some method_name)
    (D.writes trace)

let one label = function
  | [ value ] -> value
  | [] | _ :: _ :: _ -> Alcotest.fail (label ^ ": expected exactly one message")

let json_equal label expected actual =
  Alcotest.check Alcotest.bool label true (Json.equal expected actual)

let has_text source fragment =
  let last = String.length source - String.length fragment in
  let rec search offset =
    if offset > last then false
    else if String.sub source offset (String.length fragment) = fragment then
      true
    else search (offset + 1)
  in
  search 0

let handshake_and_policy () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let turns = ref 0 in
      let turn peer call =
        incr turns;
        let id = "turn-" ^ string_of_int !turns in
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ]);
        D.completed peer ~id ~status:"completed" ()
      in
      let process = D.process trace (D.server ~turn) in
      let result =
        call_session ~trace ~process ~clock ~interrupt (fun session ->
            match
              Session.turn session ~prompt:"First task" ~emit:(fun _ -> ())
            with
            | Error error -> Error error
            | Ok _ ->
                Session.turn session ~prompt:"Continue task" ~emit:(fun _ -> ()))
      in
      check_tag "completed" result;
      let launches =
        List.filter_map
          (function
            | D.Launch { cwd; command; env } -> Some (cwd, command, env)
            | D.Write _
            | D.Read_stdout _
            | D.Read_stderr _
            | D.Process_closing
            | D.Process_closed
            | D.Workspace_acquired
            | D.After_run
            | D.Lease_closing
            | D.Lease_released -> None)
          (D.events trace)
      in
      let cwd, command, environment = one "scoped launch" launches in
      Alcotest.check Alcotest.string "actual checked path" D.cwd cwd;
      Alcotest.check Alcotest.string "configured command" "agent app-server"
        command;
      Alcotest.check
        (Alcotest.list (Alcotest.pair Alcotest.string Alcotest.string))
        "only explicitly exported environment"
        [ ("MARKER", "agent-test") ]
        environment;
      let methods = List.filter_map D.method_name (D.writes trace) in
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "handshake and same session"
        [
          "initialize";
          "initialized";
          "thread/start";
          "thread/name/set";
          "turn/start";
          "turn/start";
        ]
        methods;
      let initialize =
        one "initialize" (calls trace "initialize") |> D.field "params"
      in
      let info = D.field "clientInfo" initialize in
      json_equal "client name" (D.text "symphony") (D.field "name" info);
      json_equal "actual application version" (D.text D.version)
        (D.field "version" info);
      json_equal "explicit initialization capabilities"
        (D.json
           {|{"experimentalApi":false,"explicitGatewayOauth":true,"requestAttestation":false}|})
        (D.field "capabilities" initialize);
      let thread =
        one "thread/start" (calls trace "thread/start") |> D.field "params"
      in
      json_equal "thread cwd" (D.text D.cwd) (D.field "cwd" thread);
      json_equal "thread approval" (D.text "never")
        (D.field "approvalPolicy" thread);
      json_equal "thread shorthand" (D.text "workspace-write")
        (D.field "sandbox" thread);
      let name =
        one "thread/name/set" (calls trace "thread/name/set")
        |> D.field "params"
      in
      json_equal "thread title" (D.text D.title) (D.field "name" name);
      let sandbox =
        D.obj
          [
            ("type", D.text "workspaceWrite");
            ( "writableRoots",
              D.json (Printf.sprintf "[%s]" (Json.encode (D.text D.cwd))) );
            ("networkAccess", D.json "false");
            ("excludeTmpdirEnvVar", D.json "true");
            ("excludeSlashTmp", D.json "true");
          ]
      in
      List.iter
        (fun call ->
          let params = D.field "params" call in
          json_equal "same thread on every turn" (D.text "thread-9")
            (D.field "threadId" params);
          json_equal "checked cwd on every turn" (D.text D.cwd)
            (D.field "cwd" params);
          json_equal "approval on every turn" (D.text "never")
            (D.field "approvalPolicy" params);
          json_equal "explicit concrete policy on every turn" sandbox
            (D.field "sandboxPolicy" params))
        (calls trace "turn/start"))

let terminal_before_ack () =
  let result, _ =
    run (fun peer call ->
        D.completed peer ~id:"turn-9" ~status:"completed" ();
        D.completed peer ~id:"turn-9" ~status:"completed" ();
        D.completed peer ~thread:"another-thread" ~id:"foreign-turn"
          ~status:"completed" ();
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]))
  in
  check_tag "completed" result;
  match result with
  | Ok ended ->
      Alcotest.check Alcotest.string "matched turn" "turn-9"
        (Turn_id.text ended.App_server.turn)
  | Error _ -> Alcotest.fail "matching early terminal was lost"

let remote_terminals () =
  let failure =
    D.json
      {|{"message":"fixture remote failure","codexErrorInfo":null,"additionalDetails":null}|}
  in
  List.iter
    (fun (status, error, expected) ->
      let result, _ =
        run (fun peer call ->
            D.reply peer call
              (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
            D.completed peer ~id:"turn-9" ~status ~error ())
      in
      check_tag expected result)
    [
      ("failed", failure, "failed-turn");
      ("interrupted", D.json "null", "interrupted-turn");
      ("interrupted", failure, "interrupted-turn");
    ]

type request_case = {
  method_name : string;
  params : Json.t;
  expected : string;
  result : Json.t -> unit;
}

let context extra =
  D.obj
    ([ ("threadId", D.text "thread-9"); ("turnId", D.text "turn-9") ] @ extra)

let deny response =
  json_equal "decline approval"
    (D.json {|{"decision":"decline"}|})
    (D.field "result" response)

let legacy response =
  let denied =
    D.field "result" response |> D.field "decision" |> D.field "denied"
  in
  Alcotest.check Alcotest.bool "legacy rejection has a reason" true
    (D.text_value (D.field "rejection" denied) <> "")

let unsupported response =
  json_equal "method-not-found code" (D.json "-32601")
    (D.field "error" response |> D.field "code")

let request_cases =
  [
    {
      method_name = "item/commandExecution/requestApproval";
      params =
        context [ ("itemId", D.text "item-9"); ("startedAtMs", D.json "0") ];
      expected = "completed";
      result = deny;
    };
    {
      method_name = "item/fileChange/requestApproval";
      params =
        context [ ("itemId", D.text "item-9"); ("startedAtMs", D.json "0") ];
      expected = "completed";
      result = deny;
    };
    {
      method_name = "item/permissions/requestApproval";
      params =
        context
          [
            ("itemId", D.text "item-9");
            ("startedAtMs", D.json "0");
            ("cwd", D.text D.cwd);
            ("permissions", D.json "{}");
          ];
      expected = "completed";
      result =
        (fun response ->
          json_equal "empty permissions only"
            (D.json {|{"permissions":{},"scope":"turn"}|})
            (D.field "result" response));
    };
    {
      method_name = "execCommandApproval";
      params =
        D.json
          {|{"conversationId":"thread-9","callId":"legacy-call","command":["true"],"cwd":"/fixture/agent/SYM-9","parsedCmd":[]}|};
      expected = "completed";
      result = legacy;
    };
    {
      method_name = "applyPatchApproval";
      params =
        D.json
          {|{"conversationId":"thread-9","callId":"legacy-call","fileChanges":{}}|};
      expected = "completed";
      result = legacy;
    };
    {
      method_name = "item/tool/call";
      params =
        context
          [
            ("tool", D.text "unknown-tool");
            ("callId", D.text "tool-call");
            ("arguments", D.json {|{"secret":"private arguments"}|});
          ];
      expected = "completed";
      result =
        (fun response ->
          let result = D.field "result" response in
          json_equal "tool failure" (D.json "false") (D.field "success" result);
          match Json.view (D.field "contentItems" result) with
          | Json.Array [ item ] ->
              json_equal "tool content tag" (D.text "inputText")
                (D.field "type" item)
          | Json.Array ([] | _ :: _ :: _)
          | Json.Null
          | Json.Bool _
          | Json.Number _
          | Json.String _
          | Json.Object _ -> Alcotest.fail "invalid tool failure contents");
    };
    {
      method_name = "mcpServer/elicitation/request";
      params =
        D.json
          {|{"serverName":"fixture","threadId":"thread-9","turnId":null,"mode":"form","message":"Supply credentials","requestedSchema":{"type":"object","properties":{}}}|};
      expected = "input-required";
      result =
        (fun response ->
          json_equal "elicitation cancellation"
            (D.json {|{"action":"cancel","content":null}|})
            (D.field "result" response));
    };
    {
      method_name = "unsupported/method";
      params = D.json "{}";
      expected = "completed";
      result = unsupported;
    };
    {
      method_name = "account/chatgptAuthTokens/refresh";
      params = D.json {|{"reason":"unauthorized"}|};
      expected = "failure";
      result = unsupported;
    };
    {
      method_name = "attestation/generate";
      params = D.json "{}";
      expected = "failure";
      result = unsupported;
    };
  ]

let request_branch case () =
  let ids =
    [
      D.text "7";
      D.json "7";
      D.json "-9223372036854775808";
      D.json "9223372036854775807";
    ]
  in
  List.iter
    (fun id ->
      let result, trace =
        run (fun peer call ->
            D.reply peer call
              (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
            D.request peer ~id case.method_name case.params;
            if case.expected = "completed" then
              D.completed peer ~id:"turn-9" ~status:"completed" ())
      in
      check_tag case.expected result;
      let responses =
        List.filter
          (fun message -> D.method_name message = None)
          (D.writes trace)
      in
      let response = one case.method_name responses in
      json_equal "outer request ID preserved exactly" id (D.field "id" response);
      case.result response)
    ids

let request_before_ack () =
  let result, trace =
    run (fun peer call ->
        let id = D.field "id" call in
        let params =
          context
            [ ("itemId", D.text "before-ack"); ("startedAtMs", D.json "0") ]
        in
        D.request peer ~id "item/commandExecution/requestApproval" params;
        D.request peer ~id "item/commandExecution/requestApproval" params;
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
        D.completed peer ~id:"turn-9" ~status:"completed" ())
  in
  check_tag "completed" result;
  let responses =
    List.filter (fun message -> D.method_name message = None) (D.writes trace)
  in
  Alcotest.check Alcotest.int "duplicate request replays the same denial" 2
    (List.length responses);
  List.iter deny responses

let usage peer id =
  D.notify peer "thread/tokenUsage/updated"
    (D.obj
       [
         ("threadId", D.text "thread-9");
         ("turnId", D.text id);
         ( "tokenUsage",
           D.json
             {|{"total":{"inputTokens":11,"cachedInputTokens":0,"outputTokens":3,"reasoningOutputTokens":0,"totalTokens":14},"last":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2}}|}
         );
       ])

let early_continuations () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let turns = ref 0 in
      let seen_usage = ref 0 in
      let emit = function
        | Agent_runner.Usage_report _ -> incr seen_usage
        | Agent_runner.Session_started _
        | Agent_runner.Turn_started _
        | Agent_runner.Turn_completed _
        | Agent_runner.Output _
        | Agent_runner.Rate_limits _
        | Agent_runner.Unsupported_tool _ -> ()
      in
      let turn peer call =
        incr turns;
        let id = "early-turn-" ^ string_of_int !turns in
        let context extra =
          D.obj
            ([ ("threadId", D.text "thread-9"); ("turnId", D.text id) ] @ extra)
        in
        D.request peer
          ~id:(D.text ("approval-" ^ id))
          "item/commandExecution/requestApproval"
          (context
             [ ("itemId", D.text "early-item"); ("startedAtMs", D.json "0") ]);
        D.request peer
          ~id:(D.text ("tool-" ^ id))
          "item/tool/call"
          (context
             [
               ("tool", D.text "early-tool");
               ("callId", D.text "early-call");
               ("arguments", D.json "{}");
             ]);
        usage peer id;
        D.completed peer ~id ~status:"completed" ();
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ])
      in
      let process = D.process trace (D.server ~turn) in
      let result =
        call_session ~trace ~process ~clock ~interrupt (fun session ->
            match Session.turn session ~prompt:"Initial" ~emit with
            | Error error -> Error error
            | Ok _ -> Session.turn session ~prompt:"Continuation" ~emit)
      in
      check_tag "completed" result;
      Alcotest.check Alcotest.int "usage survives both pending start responses"
        2 !seen_usage;
      Alcotest.check Alcotest.int "both turns answer approval and tool requests"
        4
        (List.length
           (List.filter
              (fun message -> D.method_name message = None)
              (D.writes trace))))

let conflicting_early_id () =
  let result, _ =
    run (fun peer call ->
        D.request peer ~id:(D.text "early-approval")
          "item/commandExecution/requestApproval"
          (context
             [ ("itemId", D.text "early-item"); ("startedAtMs", D.json "0") ]);
        D.reply peer call
          (D.obj
             [ ("turn", D.turn ~id:"conflicting-turn" ~status:"inProgress" ()) ]);
        D.completed peer ~id:"conflicting-turn" ~status:"completed" ())
  in
  check_tag "failure" result

let user_input () =
  let result, trace =
    run (fun peer call ->
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
        D.request peer ~id:(D.text "input-9") "item/tool/requestUserInput"
          (context
             [
               ("itemId", D.text "input-item");
               ("isBlocking", D.json "true");
               ( "questions",
                 D.json
                   {|[{"id":"q","header":"Choice","question":"Continue?"}]|} );
             ]))
  in
  check_tag "input-required" result;
  Alcotest.check Alcotest.int "no fabricated answer" 0
    (List.length
       (List.filter
          (fun message -> D.method_name message = None)
          (D.writes trace)));
  Alcotest.check Alcotest.int "input interrupts active turn" 1
    (List.length (calls trace "turn/interrupt"))

let malformed_and_eof () =
  let observed = ref [] in
  let result, _ =
    run
      ~emit:(fun event -> observed := event :: !observed)
      (fun peer call ->
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
        D.send peer
          "{\"method\":\"fixture/before\",\"params\":{\"threadId\":\"thread-9\",\"turnId\":\"turn-9\"}}\n\
           {broken}\n";
        D.completed peer ~id:"turn-9" ~status:"completed" ())
  in
  check_tag "failure" result;
  Alcotest.check Alcotest.bool "accepted prefix remains observable" true
    (List.exists
       (function
         | Agent_runner.Output { event_name; _ } ->
             event_name = "fixture/before"
         | Agent_runner.Session_started _
         | Agent_runner.Turn_started _
         | Agent_runner.Turn_completed _
         | Agent_runner.Usage_report _
         | Agent_runner.Rate_limits _
         | Agent_runner.Unsupported_tool _ -> false)
       !observed);
  let eof_result, _ =
    run (fun peer call ->
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
        D.send peer {|{"method":"turn/completed"|};
        D.eof peer)
  in
  check_tag "failure" eof_result

let scheduled ?(before_write = fun _ _ -> ()) ~on_write ~emit use =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let trace = D.trace () in
          let mono, clock = D.clock () in
          let interrupt, resolver = Eio.Promise.create () in
          let peer = ref None in
          let process =
            D.process
              ~on_launch:(fun value -> peer := Some value)
              trace
              (fun peer call ->
                before_write trace call;
                on_write peer call)
          in
          let result, returned = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              Eio.Promise.resolve returned
                (call_session ~trace ~process ~clock ~interrupt (fun session ->
                     Session.turn session ~prompt:"Scheduled task" ~emit)));
          let get_peer () =
            match !peer with
            | Some peer -> peer
            | None -> Alcotest.fail "peer was not launched"
          in
          use ~trace ~mono ~resolver ~result ~peer:get_peer))

let early_input_terminal () =
  List.iter
    (fun target_turn ->
      Eio_mock.Backend.run (fun () ->
          Eio.Switch.run (fun sw ->
              let trace = D.trace () in
              let mono, clock = D.clock () in
              let interrupt, _ = Eio.Promise.create () in
              let acknowledged = D.gate () in
              let turns = ref 0 in
              let observed = ref None in
              let read_goal = ref None in
              let handler peer call =
                match D.method_name call with
                | Some "turn/start" ->
                    incr turns;
                    let id = "input-turn-" ^ string_of_int !turns in
                    if !turns = target_turn then
                      D.request peer ~id:(D.text "early-input")
                        "item/tool/requestUserInput"
                        (D.obj
                           [
                             ("threadId", D.text "thread-9");
                             ("turnId", D.text id);
                             ("itemId", D.text "input-item");
                             ("isBlocking", D.json "true");
                             ( "questions",
                               D.json
                                 {|[{"id":"q","header":"Choice","question":"Continue?"}]|}
                             );
                           ]);
                    D.reply peer call
                      (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ]);
                    if !turns <> target_turn then
                      D.completed peer ~id ~status:"completed" ()
                | Some "turn/interrupt" ->
                    let bytes =
                      Json.encode
                        (D.obj
                           [
                             ("id", D.field "id" call); ("result", D.json "{}");
                           ])
                      ^ "\n"
                    in
                    observed :=
                      Some
                        ( peer,
                          D.field "params" call |> D.field "turnId"
                          |> D.text_value );
                    read_goal := Some (stdout_bytes trace + String.length bytes);
                    D.send peer bytes;
                    D.release acknowledged
                | Some _ | None -> D.server ~turn:completed_turn peer call
              in
              let process = D.process trace handler in
              let result, resolver = Eio.Promise.create () in
              Eio.Fiber.fork ~sw (fun () ->
                  Eio.Promise.resolve resolver
                    (call_session ~trace ~process ~clock ~interrupt
                       (fun session ->
                         let first =
                           Session.turn session ~prompt:"Initial"
                             ~emit:(fun _ -> ())
                         in
                         if target_turn = 1 then first
                         else
                           match first with
                           | Error error -> Error error
                           | Ok _ ->
                               Session.turn session ~prompt:"Continuation"
                                 ~emit:(fun _ -> ()))));
              D.await acknowledged;
              let goal =
                match !read_goal with
                | Some goal -> goal
                | None -> Alcotest.fail "Missing interrupt reply"
              in
              D.wait_event trace (fun _ -> stdout_bytes trace >= goal);
              D.advance mono 1;
              Eio.Fiber.yield ();
              Eio.Fiber.yield ();
              Alcotest.check Alcotest.bool
                "interrupt ACK is not a remote terminal" true
                (Eio.Promise.peek result = None);
              Alcotest.check Alcotest.int "early input has no fabricated answer"
                0
                (List.length
                   (List.filter
                      (fun message -> D.method_name message = None)
                      (D.writes trace)));
              let peer, id =
                match !observed with
                | Some pair -> pair
                | None -> Alcotest.fail "Missing active interruption"
              in
              Alcotest.check Alcotest.string
                "early input interrupts the provisional turn"
                ("input-turn-" ^ string_of_int target_turn)
                id;
              D.completed peer ~id ~status:"interrupted" ();
              check_tag "input-required" (Eio.Promise.await result);
              Alcotest.check Alcotest.bool
                "input-required returns after process close" true
                (has_event trace "process-closed"))))
    [ 1; 2 ]

let terminal_ack_only () =
  let active = D.gate () in
  let barriers = ref 0 in
  let emit = function
    | Agent_runner.Session_started _ | Agent_runner.Turn_started _ ->
        D.release active
    | Agent_runner.Turn_completed _ -> incr barriers
    | Agent_runner.Output _
    | Agent_runner.Usage_report _
    | Agent_runner.Rate_limits _
    | Agent_runner.Unsupported_tool _ -> ()
  in
  scheduled ~emit
    ~on_write:
      (D.server ~turn:(fun peer call ->
           D.reply peer call
             (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"completed" ()) ])))
    (fun ~trace:_ ~mono ~resolver:_ ~result ~peer:_ ->
      D.await active;
      D.advance mono 51;
      check_tag "silence-deadline" (Eio.Promise.await result);
      Alcotest.check Alcotest.int "turn ACK cannot emit a success barrier" 0
        !barriers)

let startup_interrupt () =
  let entered = D.gate () in
  scheduled
    ~on_write:(fun _peer call ->
      if D.method_name call = Some "initialize" then D.release entered)
    ~emit:(fun _ -> ())
    (fun ~trace ~mono:_ ~resolver ~result ~peer:_ ->
      D.await entered;
      Eio.Promise.resolve resolver
        (Agent_runner.Cancel Agent_runner.Scope_change);
      check_tag "canceled" (Eio.Promise.await result);
      Alcotest.check Alcotest.bool "startup cancellation closes process" true
        (has_event trace "process-closed"))

let active_interrupt requested () =
  let active = D.gate () in
  let emit = function
    | Agent_runner.Session_started _ | Agent_runner.Turn_started _ ->
        D.release active
    | Agent_runner.Turn_completed _
    | Agent_runner.Output _
    | Agent_runner.Usage_report _
    | Agent_runner.Rate_limits _
    | Agent_runner.Unsupported_tool _ -> ()
  in
  scheduled ~emit
    ~on_write:(fun peer call ->
      match D.method_name call with
      | Some "turn/interrupt" ->
          D.reply peer call (D.json "{}");
          D.completed peer ~id:"turn-9" ~status:"interrupted"
            ~error:(D.json {|{"message":"fixture interruption diagnostic"}|})
            ()
      | Some _ | None ->
          D.server
            ~turn:(fun peer call ->
              D.reply peer call
                (D.obj
                   [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]))
            peer call)
    (fun ~trace ~mono:_ ~resolver ~result ~peer:_ ->
      D.await active;
      Eio.Promise.resolve resolver requested;
      let actual = Eio.Promise.await result in
      let expected =
        match requested with
        | Agent_runner.Stall -> "stalled"
        | Agent_runner.Cancel _ -> "canceled"
      in
      check_tag expected actual;
      (match actual with
      | Error (App_server.Stopped { interrupt; remote_error }) ->
          Alcotest.check Alcotest.bool "local cause is preserved" true
            (interrupt = requested);
          Alcotest.check Alcotest.bool "remote diagnostic is separate" true
            (Option.is_some remote_error)
      | Ok _ | Error (App_server.Failure _ | App_server.Deadline _) ->
          Alcotest.fail "Expected local interruption");
      Alcotest.check Alcotest.int "one bounded interrupt request" 1
        (List.length (calls trace "turn/interrupt")))

let interrupt_rpc_failure () =
  let active = D.gate () in
  let requested = Agent_runner.Cancel Agent_runner.Scope_change in
  let emit = function
    | Agent_runner.Session_started _ | Agent_runner.Turn_started _ ->
        D.release active
    | Agent_runner.Turn_completed _
    | Agent_runner.Output _
    | Agent_runner.Usage_report _
    | Agent_runner.Rate_limits _
    | Agent_runner.Unsupported_tool _ -> ()
  in
  scheduled ~emit
    ~on_write:(fun peer call ->
      match D.method_name call with
      | Some "turn/interrupt" ->
          D.send peer
            (Json.encode
               (D.obj
                  [
                    ("id", D.field "id" call);
                    ( "error",
                      D.json
                        {|{"code":-32000,"message":"remote-private-interrupt-message","data":{"secret":"remote-private-interrupt-data"}}|}
                    );
                  ])
            ^ "\n")
      | Some _ | None ->
          D.server
            ~turn:(fun peer call ->
              D.reply peer call
                (D.obj
                   [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]))
            peer call)
    (fun ~trace ~mono:_ ~resolver ~result ~peer:_ ->
      D.await active;
      Eio.Promise.resolve resolver requested;
      let actual = Eio.Promise.await result in
      (match actual with
      | Error (App_server.Stopped { interrupt; remote_error = Some diagnostic })
        ->
          Alcotest.check Alcotest.bool
            "rejected interrupt retains its local cause" true
            (interrupt = requested);
          let rendered = Diagnostic.render diagnostic in
          Alcotest.check Alcotest.bool "interrupt RPC code remains observable"
            true
            (has_text rendered "-32000");
          List.iter
            (fun secret ->
              Alcotest.check Alcotest.bool "interrupt remote prose is absent"
                false (has_text rendered secret))
            [
              "remote-private-interrupt-message";
              "remote-private-interrupt-data";
            ]
      | Error (App_server.Stopped { remote_error = None; _ }) ->
          Alcotest.fail "Rejected interrupt RPC lost its remote diagnostic"
      | Ok _ | Error (App_server.Failure _ | App_server.Deadline _) ->
          Alcotest.fail
            "Rejected interrupt RPC replaced its local cancellation cause");
      Alcotest.check Alcotest.int "rejected interrupt is attempted once" 1
        (List.length (calls trace "turn/interrupt"));
      Alcotest.check Alcotest.bool
        "rejected interrupt closes its process before return" true
        (has_event trace "process-closed"))

let initial_rate_limits () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let snapshot =
        D.json
          {|{"limitId":"initial-only","primary":{"usedPercent":17,"resetsAt":9007199254740993}}|}
      in
      let turn_count = ref 0 in
      let turn peer call =
        incr turn_count;
        let id = "rate-turn-" ^ string_of_int !turn_count in
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id ~status:"inProgress" ()) ]);
        D.completed peer ~id ~status:"completed" ()
      in
      let process =
        D.process trace (fun peer call ->
            (match D.method_name call with
            | Some "initialize" ->
                D.notify peer "account/rateLimits/updated"
                  (D.obj [ ("rateLimits", snapshot) ])
            | Some _ | None -> ());
            D.server ~turn peer call)
      in
      let first_rates = ref [] and later_rates = ref [] in
      let observe rates = function
        | Agent_runner.Rate_limits value -> rates := value :: !rates
        | Agent_runner.Session_started _
        | Agent_runner.Turn_started _
        | Agent_runner.Turn_completed _
        | Agent_runner.Output _
        | Agent_runner.Usage_report _
        | Agent_runner.Unsupported_tool _ -> ()
      in
      let result =
        call_session ~trace ~process ~clock ~interrupt (fun session ->
            let first =
              Session.turn session ~prompt:"First rates observer"
                ~emit:(observe first_rates)
            in
            check_tag "completed" first;
            json_equal "initial snapshot reaches the first turn unchanged"
              snapshot
              (one "sole initialization rate snapshot" !first_rates);
            Session.turn session ~prompt:"Continuation rates observer"
              ~emit:(observe later_rates))
      in
      check_tag "completed" result;
      Alcotest.check Alcotest.int
        "initial snapshot is not replayed on continuation" 0
        (List.length !later_rates);
      Alcotest.check Alcotest.bool "initial-rate attempt closes before return"
        true
        (has_event trace "process-closed"))

let fixed_rpc_deadline () =
  scheduled
    ~emit:(fun _ -> ())
    ~on_write:(fun _peer _call -> ())
    (fun ~trace ~mono ~resolver:_ ~result ~peer ->
      wait trace "write";
      D.advance mono 10;
      D.notify (peer ()) "fixture/noise" (D.json "{}");
      wait trace "stdout";
      D.advance mono 21;
      check_tag "rpc-deadline" (Eio.Promise.await result))

let write_backpressure () =
  let entered = D.gate () in
  let blocked = D.gate () in
  scheduled
    ~emit:(fun _ -> ())
    ~on_write:(fun _peer call ->
      if D.method_name call = Some "initialize" then (
        D.release entered;
        D.await blocked))
    (fun ~trace ~mono ~resolver:_ ~result ~peer:_ ->
      Fun.protect
        ~finally:(fun () -> D.release blocked)
        (fun () ->
          D.await entered;
          D.advance mono 21;
          check_tag "rpc-deadline" (Eio.Promise.await result);
          Alcotest.check Alcotest.bool "blocked writer is joined" true
            (has_event trace "process-closed")))

let silence_deadline stream () =
  let active = D.gate () in
  let emit = function
    | Agent_runner.Session_started _ | Agent_runner.Turn_started _ ->
        D.release active
    | Agent_runner.Turn_completed _
    | Agent_runner.Output _
    | Agent_runner.Usage_report _
    | Agent_runner.Rate_limits _
    | Agent_runner.Unsupported_tool _ -> ()
  in
  scheduled ~emit
    ~on_write:
      (D.server ~turn:(fun peer call ->
           D.reply peer call
             (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ])))
    (fun ~trace ~mono ~resolver:_ ~result ~peer ->
      D.await active;
      D.advance mono 40;
      (match stream with
      | `Stderr ->
          D.stderr (peer ()) "private stderr bytes";
          wait trace "stderr"
      | `Stdout ->
          D.send (peer ()) "{";
          D.wait_event trace (function
            | D.Read_stdout 1 -> true
            | D.Launch _
            | D.Write _
            | D.Read_stdout _
            | D.Read_stderr _
            | D.Process_closing
            | D.Process_closed
            | D.Workspace_acquired
            | D.After_run
            | D.Lease_closing
            | D.Lease_released -> false));
      D.advance mono 51;
      match stream with
      | `Stderr -> check_tag "silence-deadline" (Eio.Promise.await result)
      | `Stdout ->
          Alcotest.check Alcotest.bool "stdout reset survives original deadline"
            true
            (Eio.Promise.peek result = None);
          D.advance mono 91;
          check_tag "silence-deadline" (Eio.Promise.await result))

let resolved_interrupt () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, resolver = Eio.Promise.create () in
      Eio.Promise.resolve resolver
        (Agent_runner.Cancel Agent_runner.Host_shutdown);
      let process = D.process trace (D.server ~turn:completed_turn) in
      let result =
        call_session ~trace ~process ~clock ~interrupt (fun session ->
            Session.turn session ~prompt:"unused" ~emit:(fun _ -> ()))
      in
      check_tag "canceled" result;
      Alcotest.check Alcotest.int "resolved stop acquires nothing" 0
        (List.length (D.events trace)))

let unchanged_defect () =
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let marker = Failure "original peer defect" in
      let process = D.process trace (fun _ _ -> raise marker) in
      let caught =
        try
          ignore
            (call_session ~trace ~process ~clock ~interrupt (fun session ->
                 Session.turn session ~prompt:"unused" ~emit:(fun _ -> ())));
          false
        with error -> error == marker
      in
      Alcotest.check Alcotest.bool "same exception after closure" true caught;
      Alcotest.check Alcotest.bool "defect closes peer" true
        (has_event trace "process-closed"))

let bad_response messages () =
  let sent = D.gate () in
  let read_goal = ref 0 in
  scheduled
    ~emit:(fun _ -> ())
    ~before_write:(fun trace call ->
      if D.method_name call = Some "turn/start" then
        read_goal := stdout_bytes trace)
    ~on_write:(fun peer call ->
      match D.method_name call with
      | Some "turn/start" ->
          let bytes =
            List.map (fun message -> Json.encode message ^ "\n") (messages call)
          in
          List.iter
            (fun value -> read_goal := !read_goal + String.length value)
            bytes;
          List.iter (D.send peer) bytes;
          D.release sent
      | Some _ | None -> D.server ~turn:completed_turn peer call)
    (fun ~trace ~mono ~resolver:_ ~result ~peer:_ ->
      D.await sent;
      D.wait_event trace (fun _ ->
          stdout_bytes trace >= !read_goal || has_event trace "process-closed");
      D.advance mono 51;
      let actual = Eio.Promise.await result in
      Alcotest.check Alcotest.bool
        "uncorrelated response cannot finish pending turn" true
        (result_tag actual <> "completed"))

let response_correlation () =
  bad_response
    (fun _ ->
      [
        D.obj
          [
            ("id", D.text "unknown-response");
            ( "result",
              D.obj [ ("turn", D.turn ~id:"wrong-turn" ~status:"completed" ()) ]
            );
          ];
      ])
    ()

let repeated_response () =
  bad_response
    (fun call ->
      List.map
        (fun turn ->
          D.obj
            [ ("id", D.field "id" call); ("result", D.obj [ ("turn", turn) ]) ])
        [
          D.turn ~id:"turn-9" ~status:"inProgress" ();
          D.turn ~id:"wrong-turn" ~status:"completed" ();
        ])
    ()

let early_limit count error expected =
  Eio_mock.Backend.run (fun () ->
      Eio.Switch.run (fun sw ->
          let trace = D.trace () in
          let _, clock = D.clock () in
          let interrupt, _ = Eio.Promise.create () in
          (* A server writes independently while the client owns its RPC. *)
          let turn peer call =
            Eio.Fiber.fork ~sw (fun () ->
                let status =
                  match error with
                  | None -> "completed"
                  | Some _ -> "interrupted"
                in
                for _index = 1 to count do
                  D.completed peer ~id:"turn-9" ~status ?error ()
                done;
                D.reply peer call
                  (D.obj
                     [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]))
          in
          let process = D.process trace (D.server ~turn) in
          let result =
            call_session ~trace ~process ~clock ~interrupt (fun session ->
                Session.turn session ~prompt:"bounded early records"
                  ~emit:(fun _ -> ()))
          in
          check_tag expected result))

let early_ceiling () = early_limit 129 None "failure"

let early_byte_ceiling () =
  let message_bytes = (Protocol_frame.max_bytes / 2) + 1 in
  let error = D.obj [ ("message", D.text (String.make message_bytes 'x')) ] in
  let record =
    D.obj
      [
        ("method", D.text "turn/completed");
        ( "params",
          D.obj
            [
              ("threadId", D.text "thread-9");
              ("turn", D.turn ~id:"turn-9" ~status:"interrupted" ~error ());
            ] );
      ]
  in
  let encoded = String.length (Json.encode record) in
  Alcotest.check Alcotest.bool "each early record fits the frame bound" true
    (encoded <= Protocol_frame.max_bytes);
  Alcotest.check Alcotest.bool "combined early records exceed their byte bound"
    true
    (2 * encoded > Protocol_frame.max_bytes);
  early_limit 1 (Some error) "interrupted-turn";
  early_limit 2 (Some error) "failure"

let record_ceiling () =
  let request_count = 129 in
  let answered = ref 0 in
  let handler peer call =
    match D.method_name call with
    | Some "turn/start" ->
        D.reply peer call
          (D.obj [ ("turn", D.turn ~id:"turn-9" ~status:"inProgress" ()) ]);
        D.request peer ~id:(D.text "budget-1") "unsupported/method"
          (D.json "{}")
    | None ->
        incr answered;
        if !answered = request_count then
          D.completed peer ~id:"turn-9" ~status:"completed" ()
        else
          D.request peer
            ~id:(D.text ("budget-" ^ string_of_int (!answered + 1)))
            "unsupported/method" (D.json "{}")
    | Some _ -> D.server ~turn:completed_turn peer call
  in
  Eio_mock.Backend.run (fun () ->
      let trace = D.trace () in
      let _, clock = D.clock () in
      let interrupt, _ = Eio.Promise.create () in
      let process = D.process trace handler in
      let result =
        call_session ~trace ~process ~clock ~interrupt (fun session ->
            Session.turn session ~prompt:"bounded requests" ~emit:(fun _ -> ()))
      in
      check_tag "failure" result;
      Alcotest.check Alcotest.bool
        "no eviction admits an unbounded replay stream" true
        (!answered < request_count))

let suite () =
  let example = Alcotest.test_case in
  let branches =
    List.map
      (fun case ->
        example
          ("server request: " ^ case.method_name)
          `Quick (request_branch case))
      request_cases
  in
  ( "owned app-server session",
    [
      example "handshake, name and explicit same-thread policies" `Quick
        handshake_and_policy;
      example "early terminals, duplicates and foreign thread" `Quick
        terminal_before_ack;
      example "remote failed and interrupted terminals retain their outcomes"
        `Quick remote_terminals;
      example "interleaved colliding request IDs replay before turn ack" `Quick
        request_before_ack;
      example "early approval, tool, usage and completion on both turns" `Quick
        early_continuations;
      example "conflicting early turn identity is rejected" `Quick
        conflicting_early_id;
      example "user input has no invented answer" `Quick user_input;
      example
        "early input waits past interrupt ACK for remote terminal on both turns"
        `Quick early_input_terminal;
      example "completed turn/start ACK alone cannot prove turn completion"
        `Quick terminal_ack_only;
      example "malformed prefix and truncated EOF cannot succeed" `Quick
        malformed_and_eof;
      example "startup cancellation wakes blocked RPC" `Quick startup_interrupt;
      example "active stall preserves its cause and remote diagnostic" `Quick
        (active_interrupt Agent_runner.Stall);
      example "active cancellation preserves its cause and remote diagnostic"
        `Quick
        (active_interrupt (Agent_runner.Cancel Agent_runner.Reconciliation));
      example
        "interrupt RPC failure retains local cause and sanitized remote code"
        `Quick interrupt_rpc_failure;
      example "initial rate snapshot reaches the first observer exactly once"
        `Quick initial_rate_limits;
      example "unrelated stdout cannot extend fixed RPC deadline" `Quick
        fixed_rpc_deadline;
      example "RPC deadline includes blocked writes" `Quick write_backpressure;
      example "stderr cannot reset turn silence" `Quick
        (silence_deadline `Stderr);
      example "partial stdout bytes reset turn silence" `Quick
        (silence_deadline `Stdout);
      example "resolved interruption acquires no process" `Quick
        resolved_interrupt;
      example "unrelated defect retains exception identity" `Quick
        unchanged_defect;
      example "unknown response cannot complete a pending RPC" `Quick
        response_correlation;
      example "repeated response cannot complete a pending turn" `Quick
        repeated_response;
      example "early envelopes stop at the declared ceiling" `Quick
        early_ceiling;
      example "early envelopes share one bounded encoded-byte budget" `Quick
        early_byte_ceiling;
      example "replay records stop at the declared ceiling" `Quick
        record_ceiling;
    ]
    @ branches )
