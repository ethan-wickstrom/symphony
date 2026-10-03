module Codec = Protocol_codec

type fixture = { name : string; schema : string; value : Json.t }

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected checked protocol data"

let json source = get (Json.parse source)

let lookup key fields =
  match List.assoc_opt key fields with
  | Some value -> value
  | None -> Alcotest.fail ("missing protocol fixture field: " ^ key)

let contains text fragment =
  let length = String.length fragment in
  let limit = String.length text - length in
  let rec seek index =
    index <= limit
    && (String.sub text index length = fragment || seek (index + 1))
  in
  seek 0

let replace key value source =
  match Json.view source with
  | Json.Object fields ->
      get
        (Json.of_view
           (Json.Object ((key, value) :: List.remove_assoc key fields)))
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      Alcotest.fail "test fixture is not an object"

let id = get (Protocol_id.of_string "rpc-1")
let thread = get (Thread_id.parse "thread-1")
let turn = get (Turn_id.parse "turn-1")
let cwd = "/workspace/EX-123"

let thread_policy =
  json {|{"approvalPolicy":"never","sandbox":"workspace-write"}|}

let turn_policy =
  json
    {|{"approvalPolicy":"never","sandboxPolicy":{"type":"workspaceWrite","writableRoots":["/workspace/EX-123"],"networkAccess":false,"excludeSlashTmp":true,"excludeTmpdirEnvVar":true}}|}

let calls =
  [
    ("initialize", Codec.Initialize { version = "0.1.0" });
    ("thread-start", Codec.Start_thread { cwd; policy = thread_policy });
    ("thread-name", Codec.Name_thread { thread; name = "EX-123: Example" });
    ( "turn-start",
      Codec.Start_turn { thread; cwd; policy = turn_policy; prompt = "Work" } );
    ("interrupt", Codec.Interrupt { thread; turn });
  ]

let server_inputs =
  [
    ( "command",
      "item/commandExecution/requestApproval",
      "CommandExecutionRequestApprovalResponse.json",
      {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":9223372036854775807}|}
    );
    ( "file",
      "item/fileChange/requestApproval",
      "FileChangeRequestApprovalResponse.json",
      {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":-9223372036854775808}|}
    );
    ( "permissions",
      "item/permissions/requestApproval",
      "PermissionsRequestApprovalResponse.json",
      {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":0,"cwd":"untrusted/path","permissions":{"network":{"enabled":true}}}|}
    );
    ( "tool",
      "item/tool/call",
      "DynamicToolCallResponse.json",
      {|{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":"unsupported","arguments":null}|}
    );
    ( "elicitation",
      "mcpServer/elicitation/request",
      "McpServerElicitationRequestResponse.json",
      {|{"threadId":"thread-1","turnId":null,"serverName":"mcp","mode":"url","message":"remote-secret","url":"https://example.invalid","elicitationId":"e-1"}|}
    );
    ( "legacy-exec",
      "execCommandApproval",
      "ExecCommandApprovalResponse.json",
      {|{"conversationId":"thread-1","callId":"call-1","cwd":"untrusted/path","command":["true"],"parsedCmd":[]}|}
    );
    ( "legacy-patch",
      "applyPatchApproval",
      "ApplyPatchApprovalResponse.json",
      {|{"conversationId":"thread-1","callId":"call-1","fileChanges":{"a":{"type":"add","content":"remote-secret"}}}|}
    );
    ( "auth",
      "account/chatgptAuthTokens/refresh",
      "JSONRPCError.json",
      {|{"reason":"unauthorized"}|} );
    ("attestation", "attestation/generate", "JSONRPCError.json", "{}");
    ("unknown", "future/method", "JSONRPCError.json", "null");
  ]

let action ?(id = id) method_name source =
  get (Codec.server_request ~id ~method_name (Some (json source)))

let action_response = function
  | Codec.Reply { response; _ } | Codec.Unsupported response -> response
  | Codec.Input_required { response = Some response; _ } -> response
  | Codec.Input_required { response = None; _ } ->
      Alcotest.fail "no response is expected"

let fixtures () =
  let identities =
    [
      ("", id);
      ("-id-min", Protocol_id.of_int64 Int64.min_int);
      ("-id-max", Protocol_id.of_int64 Int64.max_int);
    ]
  in
  let requests =
    List.concat_map
      (fun (suffix, id) ->
        List.map
          (fun (name, call) ->
            let value =
              get (Protocol_envelope.encode (get (Codec.request ~id call)))
            in
            { name = name ^ suffix; schema = "ClientRequest.json"; value })
          calls)
      identities
  in
  let initialized =
    {
      name = "initialized";
      schema = "ClientNotification.json";
      value = get (Protocol_envelope.encode (get (Codec.initialized ())));
    }
  in
  let responses =
    List.concat_map
      (fun (suffix, id) ->
        List.concat_map
          (fun (name, method_name, schema, source) ->
            let name = name ^ suffix in
            let response = action_response (action ~id method_name source) in
            let value = get (Protocol_envelope.encode response) in
            match Protocol_envelope.view response with
            | Protocol_envelope.Response
                { reply = Protocol_envelope.Success result; _ } ->
                [
                  {
                    name = name ^ "-envelope";
                    schema = "JSONRPCResponse.json";
                    value;
                  };
                  { name = name ^ "-result"; schema; value = result };
                ]
            | Protocol_envelope.Response
                { reply = Protocol_envelope.Failure _; _ } ->
                [ { name; schema = "JSONRPCError.json"; value } ]
            | Protocol_envelope.Request _ | Protocol_envelope.Notification _ ->
                Alcotest.fail "server response changed envelope shape")
          server_inputs)
      identities
  in
  (initialized :: requests) @ responses

let encoders () =
  let initialization =
    get (Codec.request ~id (Codec.Initialize { version = "0.1.0" }))
  in
  let expected =
    json
      {|{"id":"rpc-1","method":"initialize","params":{"clientInfo":{"name":"symphony","version":"0.1.0"},"capabilities":{"experimentalApi":false,"explicitGatewayOauth":true,"requestAttestation":false}}}|}
  in
  Alcotest.(check bool)
    "explicit stable handshake" true
    (Json.equal expected (get (Protocol_envelope.encode initialization)));
  Alcotest.(check bool)
    "initialized has no params" true
    (Json.equal
       (json {|{"method":"initialized"}|})
       (get (Protocol_envelope.encode (get (Codec.initialized ())))));
  List.iter (fun (_, call) -> ignore (get (Codec.request ~id call))) calls;
  let encoded =
    get
      (Protocol_envelope.encode
         (get (Codec.request ~id (lookup "turn-start" calls))))
  in
  let expected =
    json
      {|{"id":"rpc-1","method":"turn/start","params":{"threadId":"thread-1","cwd":"/workspace/EX-123","approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":["/workspace/EX-123"],"networkAccess":false,"excludeSlashTmp":true,"excludeTmpdirEnvVar":true},"input":[{"type":"text","text":"Work"}]}}|}
  in
  Alcotest.(check bool)
    "turn re-sends accepted policy" true
    (Json.equal expected encoded)

let reply_shapes () =
  let call = Codec.Start_thread { cwd; policy = thread_policy } in
  let valid =
    json
      {|{"thread":{"id":"thread-1","cwd":"/workspace/EX-123"},"cwd":"/workspace/EX-123","approvalPolicy":"never","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"},"model":"open-model","modelProvider":"open-provider"}|}
  in
  (match get (Codec.reply call valid) with
  | Codec.Thread_started actual ->
      Alcotest.(check bool) "thread ID" true (Thread_id.equal thread actual)
  | Codec.Initialized | Codec.Named | Codec.Turn_started _ | Codec.Interrupt_ack
    -> Alcotest.fail "wrong thread reply");
  List.iter
    (fun (key, value) ->
      Alcotest.(check bool)
        "policy/cwd mismatch fails" true
        (Result.is_error (Codec.reply call (replace key value valid))))
    [
      ("cwd", json {|"/other"|});
      ("approvalPolicy", json {|"on-request"|});
      ("approvalsReviewer", json {|"auto_review"|});
      ("sandbox", json {|{"type":"readOnly"}|});
      ("thread", json {|{"id":"thread-1","cwd":"/other"}|});
    ];
  Alcotest.(check bool)
    "initialize required fields" true
    (Result.is_error
       (Codec.reply (Codec.Initialize { version = "0.1.0" }) (json "{}")))

let policies () =
  let expected =
    json
      {|{"approvalPolicy":{"granular":{"mcp_elicitations":false,"rules":false,"sandbox_approval":false}},"sandboxPolicy":{"type":"workspaceWrite"}}|}
  in
  let approval =
    json
      {|{"granular":{"mcp_elicitations":false,"rules":false,"sandbox_approval":false,"skill_approval":false,"request_permissions":false}}|}
  in
  ignore
    (get
       (Codec.check_turn_policy ~expected ~approval
          ~sandbox:
            (json
               {|{"type":"workspaceWrite","networkAccess":false,"writableRoots":[],"excludeTmpdirEnvVar":false,"excludeSlashTmp":false,"future":true}|})));
  Alcotest.(check bool)
    "broader sandbox rejected" true
    (Result.is_error
       (Codec.check_turn_policy ~expected ~approval
          ~sandbox:(json {|{"type":"workspaceWrite","networkAccess":true}|})))

let terminals () =
  List.iter
    (fun (status, expected) ->
      let value =
        json
          (Printf.sprintf
             {|{"threadId":"thread-1","turn":{"id":"turn-1","status":"%s","items":[],"startedAt":-9223372036854775808,"completedAt":9223372036854775807}}|}
             status)
      in
      match
        get (Codec.notification ~method_name:"turn/completed" (Some value))
      with
      | Codec.Turn_completed_notice { turn; _ } ->
          Alcotest.(check bool)
            "exact status" true
            (turn.Codec.status = expected)
      | Codec.Turn_started_notice _
      | Codec.Usage _
      | Codec.Rate_limits _
      | Codec.Request_resolved _
      | Codec.Settings _
      | Codec.Other _ -> Alcotest.fail "wrong terminal notice")
    [
      ("completed", Codec.Completed);
      ("failed", Codec.Failed);
      ("interrupted", Codec.Interrupted);
      ("inProgress", Codec.In_progress);
    ];
  List.iter
    (fun source ->
      Alcotest.(check bool)
        "malformed terminal fails" true
        (Result.is_error
           (Codec.notification ~method_name:"turn/completed"
              (Some (json source)))))
    [
      {|{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}|};
      {|{"threadId":"thread-1","turn":{"id":"turn-1","status":"success","items":[]}}|};
      {|{"threadId":"thread-1","turn":{"id":"turn-1","status":"failed","items":[],"error":{}}}|};
    ]

let telemetry () =
  let usage_source counter =
    Printf.sprintf
      {|{"threadId":"thread-1","turnId":"turn-1","tokenUsage":{"total":{"inputTokens":9223372036854775807,"outputTokens":2,"totalTokens":3,"cachedInputTokens":0,"reasoningOutputTokens":0},"last":{"inputTokens":%s,"outputTokens":0,"totalTokens":0,"cachedInputTokens":0,"reasoningOutputTokens":0}}}|}
      counter
  in
  (match
     get
       (Codec.notification ~method_name:"thread/tokenUsage/updated"
          (Some (json (usage_source "0"))))
   with
  | Codec.Usage { absolute; _ } ->
      Alcotest.(check string)
        "full signed64 count" "9223372036854775807"
        (Count.decimal (Usage.input absolute));
      Alcotest.(check string)
        "independent absolute total" "3"
        (Count.decimal (Usage.total absolute))
  | Codec.Turn_started_notice _
  | Codec.Turn_completed_notice _
  | Codec.Rate_limits _
  | Codec.Request_resolved _
  | Codec.Settings _
  | Codec.Other _ -> Alcotest.fail "wrong usage notice");
  List.iter
    (fun counter ->
      Alcotest.(check bool)
        "invalid last also rejects report" true
        (Result.is_error
           (Codec.notification ~method_name:"thread/tokenUsage/updated"
              (Some (json (usage_source counter))))))
    [ "-1"; "1.0"; "1e0"; "9223372036854775808" ];
  let base = json (usage_source "0") in
  let get_field key value =
    match Json.view value with
    | Json.Object fields -> lookup key fields
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Alcotest.fail "usage fixture is not an object"
  in
  let tokens = get_field "tokenUsage" base in
  List.iter
    (fun scope ->
      List.iter
        (fun counter ->
          let breakdown =
            replace counter (json "-1") (get_field scope tokens)
          in
          let malformed =
            replace "tokenUsage" (replace scope breakdown tokens) base
          in
          Alcotest.(check bool)
            "every breakdown counter is nonnegative" true
            (Result.is_error
               (Codec.notification ~method_name:"thread/tokenUsage/updated"
                  (Some malformed))))
        [
          "inputTokens";
          "outputTokens";
          "totalTokens";
          "cachedInputTokens";
          "reasoningOutputTokens";
          "cacheWriteInputTokens";
        ])
    [ "total"; "last" ];
  let snapshot =
    json
      {|{"planType":"promax","primary":null,"secondary":{"usedPercent":100,"resetsAt":9223372036854775807},"normalModelSlug":null,"spendControlReached":null,"future":true}|}
  in
  let value = get (Json.of_view (Json.Object [ ("rateLimits", snapshot) ])) in
  match
    get
      (Codec.notification ~method_name:"account/rateLimits/updated" (Some value))
  with
  | Codec.Rate_limits actual ->
      Alcotest.(check bool)
        "nullable snapshot retained" true
        (Json.equal snapshot actual)
  | Codec.Turn_started_notice _
  | Codec.Turn_completed_notice _
  | Codec.Usage _
  | Codec.Request_resolved _
  | Codec.Settings _
  | Codec.Other _ -> Alcotest.fail "wrong rate notice"

let setting_updates () =
  let valid =
    json
      {|{"threadId":"thread-1","threadSettings":{"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/workspace/EX-123","sandboxPolicy":{"type":"workspaceWrite"},"model":"open-model","modelProvider":"open-provider","collaborationMode":{"mode":"default","settings":{"model":"open-model","reasoning_effort":"future-effort","developer_instructions":null}},"effort":null,"personality":null,"disabledPluginIds":[],"activePermissionProfile":null,"serviceTier":null,"summary":null,"future":true}}|}
  in
  let fields =
    match Json.view valid with
    | Json.Object fields -> lookup "threadSettings" fields
    | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
        Alcotest.fail "settings fixture is not an object"
  in
  (match
     get
       (Codec.notification ~method_name:"thread/settings/updated" (Some valid))
   with
  | Codec.Settings { thread = actual; cwd = actual_cwd; approval; sandbox } ->
      Alcotest.(check bool)
        "settings thread" true
        (Thread_id.equal thread actual);
      Alcotest.(check string) "reported cwd remains wire data" cwd actual_cwd;
      ignore
        (get
           (Codec.check_turn_policy
              ~expected:
                (json
                   {|{"approvalPolicy":"never","sandboxPolicy":{"type":"workspaceWrite"}}|})
              ~approval ~sandbox))
  | Codec.Turn_started_notice _
  | Codec.Turn_completed_notice _
  | Codec.Usage _
  | Codec.Request_resolved _
  | Codec.Rate_limits _
  | Codec.Other _ -> Alcotest.fail "wrong settings notice");
  List.iter
    (fun (key, value) ->
      let malformed =
        replace "threadSettings" (replace key value fields) valid
      in
      Alcotest.(check bool)
        "malformed known setting fails" true
        (Result.is_error
           (Codec.notification ~method_name:"thread/settings/updated"
              (Some malformed))))
    [
      ("collaborationMode", json {|{"mode":"default","settings":{}}|});
      ("cwd", json {|"relative"|});
      ("effort", json {|""|});
      ("disabledPluginIds", json "null");
      ("approvalsReviewer", json {|"auto_review"|});
      ("sandboxPolicy", json {|{"type":"workspaceWrite","networkAccess":null}|});
    ]

let malformed_actions () =
  let inputs =
    [
      ( "item/permissions/requestApproval",
        {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":0,"cwd":"path","permissions":{"network":{"enabled":"yes"}}}|}
      );
      ( "item/permissions/requestApproval",
        {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":0,"cwd":"path","permissions":{"fileSystem":{"globScanMaxDepth":0}}}|}
      );
      ( "item/permissions/requestApproval",
        {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":0,"cwd":"path","permissions":{"unrecognized":true}}|}
      );
      ( "item/tool/requestUserInput",
        {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","isBlocking":true,"questions":[{"header":"h","id":"q","question":"?","options":[{"label":"a"}]}]}|}
      );
      ( "item/tool/requestUserInput",
        {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","isBlocking":true,"questions":[],"autoResolutionMs":18446744073709551616}|}
      );
      ( "mcpServer/elicitation/request",
        {|{"threadId":"thread-1","serverName":"mcp","message":"remote-secret","mode":"form","requestedSchema":{"type":"array","properties":{}}}|}
      );
      ( "mcpServer/elicitation/request",
        {|{"threadId":"thread-1","serverName":"mcp","message":"remote-secret","mode":"url","url":"https://example.invalid"}|}
      );
    ]
  in
  List.iter
    (fun (method_name, source) ->
      Alcotest.(check bool)
        "malformed known server input fails" true
        (Result.is_error
           (Codec.server_request ~id ~method_name (Some (json source)))))
    inputs;
  let input =
    json
      {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","isBlocking":false,"questions":[],"autoResolutionMs":18446744073709551615}|}
  in
  (match
     get
       (Codec.server_request ~id ~method_name:"item/tool/requestUserInput"
          (Some input))
   with
  | Codec.Input_required { response = None; _ } -> ()
  | Codec.Input_required { response = Some _; _ }
  | Codec.Reply _ | Codec.Unsupported _ ->
      Alcotest.fail "unsigned delay changed input policy");
  List.iter
    (fun mode ->
      let source =
        Printf.sprintf
          {|{"threadId":"thread-1","serverName":"mcp","message":"remote-secret","mode":"%s","requestedSchema":null}|}
          mode
      in
      match action "mcpServer/elicitation/request" source with
      | Codec.Input_required
          { context = { Codec.turn = None; _ }; response = Some response } ->
          let expected =
            json {|{"id":"rpc-1","result":{"action":"cancel","content":null}}|}
          in
          Alcotest.(check bool)
            "MCP cancel has no form content" true
            (Json.equal expected (get (Protocol_envelope.encode response)))
      | Codec.Input_required _ | Codec.Reply _ | Codec.Unsupported _ ->
          Alcotest.fail "uncorrelated MCP cancellation changed")
    [ "openai/form"; "openaiForm" ]

let unattended () =
  List.iter
    (fun (name, method_name, _, source) ->
      let response = action_response (action method_name source) in
      match Protocol_envelope.view response with
      | Protocol_envelope.Response { id = actual; reply } -> (
          Alcotest.(check bool)
            "outer RPC ID echoed" true
            (Protocol_id.equal id actual);
          let expected =
            match name with
            | "command" | "file" -> Some {|{"decision":"decline"}|}
            | "permissions" -> Some {|{"permissions":{},"scope":"turn"}|}
            | "tool" ->
                Some
                  {|{"success":false,"contentItems":[{"type":"inputText","text":"Unsupported tool"}]}|}
            | "elicitation" -> Some {|{"action":"cancel","content":null}|}
            | "legacy-exec" | "legacy-patch" ->
                Some
                  {|{"decision":{"denied":{"rejection":"Unattended policy denies approval"}}}|}
            | _ -> None
          in
          match (reply, expected) with
          | Protocol_envelope.Success result, Some expected ->
              Alcotest.(check bool)
                "unattended reply grants nothing" true
                (Json.equal (json expected) result)
          | ( Protocol_envelope.Failure
                {
                  Protocol_envelope.code;
                  Protocol_envelope.message;
                  Protocol_envelope.data;
                },
              None ) ->
              Alcotest.(check int64) "unsupported RPC code" (-32601L) code;
              Alcotest.(check string)
                "fixed safe RPC text" "Unsupported method" message;
              Alcotest.(check bool)
                "no opaque RPC payload" true (Option.is_none data)
          | Protocol_envelope.Success _, None
          | Protocol_envelope.Failure _, Some _ ->
              Alcotest.fail "unattended reply changed policy")
      | Protocol_envelope.Request _ | Protocol_envelope.Notification _ ->
          Alcotest.fail "not a response")
    server_inputs;
  let input =
    json
      {|{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","isBlocking":false,"questions":[]}|}
  in
  (match
     get
       (Codec.server_request ~id ~method_name:"item/tool/requestUserInput"
          (Some input))
   with
  | Codec.Input_required { response = None; _ } -> ()
  | Codec.Input_required { response = Some _; _ }
  | Codec.Reply _ | Codec.Unsupported _ ->
      Alcotest.fail "user input invented a response");
  List.iter
    (fun method_name ->
      Alcotest.(check bool)
        "known request missing required fields" true
        (Result.is_error
           (Codec.server_request ~id ~method_name (Some (json "{}")))))
    [
      "item/commandExecution/requestApproval";
      "item/fileChange/requestApproval";
      "item/permissions/requestApproval";
      "item/tool/call";
      "item/tool/requestUserInput";
      "mcpServer/elicitation/request";
      "execCommandApproval";
      "applyPatchApproval";
      "account/chatgptAuthTokens/refresh";
    ]

let redaction () =
  let value =
    json
      {|{"threadId":"thread-1","turn":{"id":"turn-1","status":"interrupted","items":[],"error":{"message":"remote-secret","additionalDetails":"another-secret","codexErrorInfo":"flexUnavailable"}}}|}
  in
  (match
     get (Codec.notification ~method_name:"turn/completed" (Some value))
   with
  | Codec.Turn_completed_notice
      { turn = { Codec.error = Some diagnostic; _ }; _ } ->
      let rendered = Diagnostic.render diagnostic in
      Alcotest.(check bool)
        "safe class survives" true
        (contains rendered "flexUnavailable");
      List.iter
        (fun secret ->
          Alcotest.(check bool)
            "remote strings discarded" false (contains rendered secret))
        [ "remote-secret"; "another-secret" ]
  | Codec.Turn_started_notice _
  | Codec.Turn_completed_notice _
  | Codec.Usage _
  | Codec.Request_resolved _
  | Codec.Rate_limits _
  | Codec.Settings _
  | Codec.Other _ -> Alcotest.fail "remote error lost");
  let expected =
    Diagnostic.render
      (Codec.diagnostic ~method_name:"turn/start" (Codec.Rpc (-32001L)))
  in
  Alcotest.(check bool)
    "RPC diagnostic retains safe numeric code" true
    (contains expected "-32001");
  let unknown_diagnostic =
    Diagnostic.render
      (Codec.diagnostic ~method_name:"secret-method-name"
         (Codec.Invalid "secret-payload"))
  in
  List.iter
    (fun secret ->
      Alcotest.(check bool)
        "unknown diagnostics discard payload" false
        (contains unknown_diagnostic secret))
    [ "secret-method-name"; "secret-payload" ];
  let unknown = json {|{"turn":{"id":"turn-1","status":"completed"}}|} in
  match
    get (Codec.notification ~method_name:"future/completed" (Some unknown))
  with
  | Codec.Other { thread = None; turn = None; _ } -> ()
  | Codec.Turn_started_notice _
  | Codec.Turn_completed_notice _
  | Codec.Usage _
  | Codec.Request_resolved _
  | Codec.Rate_limits _
  | Codec.Settings _
  | Codec.Other _ ->
      Alcotest.fail "unknown nested data created a lifecycle transition"

let tests =
  [
    Alcotest.test_case "selected outbound messages" `Quick encoders;
    Alcotest.test_case "startup policy and cwd agreement" `Quick reply_shapes;
    Alcotest.test_case "semantic policy defaults" `Quick policies;
    Alcotest.test_case "strict terminal status" `Quick terminals;
    Alcotest.test_case "exact absolute telemetry" `Quick telemetry;
    Alcotest.test_case "checked settings updates" `Quick setting_updates;
    Alcotest.test_case "unattended server actions" `Quick unattended;
    Alcotest.test_case "malformed approval and input data" `Quick
      malformed_actions;
    Alcotest.test_case "diagnostic and lifecycle boundaries" `Quick redaction;
  ]
