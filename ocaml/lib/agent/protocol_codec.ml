type error =
  | Invalid of string
  | Envelope of Protocol_envelope.error
  | Rpc of int64

type call =
  | Initialize of { version : string }
  | Start_thread of { cwd : string; policy : Json.t }
  | Name_thread of { thread : Thread_id.t; name : string }
  | Start_turn of {
      thread : Thread_id.t;
      cwd : string;
      policy : Json.t;
      prompt : string;
    }
  | Interrupt of { thread : Thread_id.t; turn : Turn_id.t }

type turn_status = In_progress | Completed | Failed | Interrupted

type turn = {
  id : Turn_id.t;
  status : turn_status;
  error : Diagnostic.t option;
}

type reply =
  | Initialized
  | Thread_started of Thread_id.t
  | Named
  | Turn_started of turn
  | Interrupt_ack

type notification =
  | Turn_started_notice of { thread : Thread_id.t; turn : turn }
  | Turn_completed_notice of { thread : Thread_id.t; turn : turn }
  | Usage of { thread : Thread_id.t; turn : Turn_id.t; absolute : Usage.t }
  | Rate_limits of Json.t
  | Request_resolved of { thread : Thread_id.t; request : Protocol_id.t }
  | Settings of {
      thread : Thread_id.t;
      cwd : string;
      approval : Json.t;
      sandbox : Json.t;
    }
  | Other of {
      method_name : string;
      thread : Thread_id.t option;
      turn : Turn_id.t option;
    }

type context = { thread : Thread_id.t option; turn : Turn_id.t option }

type server_action =
  | Reply of {
      context : context;
      response : Protocol_envelope.t;
      tool : string option;
    }
  | Input_required of {
      context : context;
      response : Protocol_envelope.t option;
    }
  | Unsupported of Protocol_envelope.t

let ( let* ) = Result.bind
let initialize_method = "initialize"
let initialized_method = "initialized"
let thread_start_method = "thread/start"
let thread_name_method = "thread/name/set"
let turn_start_method = "turn/start"
let turn_interrupt_method = "turn/interrupt"
let turn_started_method = "turn/started"
let turn_completed_method = "turn/completed"
let usage_method = "thread/tokenUsage/updated"
let rate_method = "account/rateLimits/updated"
let resolved_method = "serverRequest/resolved"
let settings_method = "thread/settings/updated"
let error_method = "error"
let command_method = "item/commandExecution/requestApproval"
let file_method = "item/fileChange/requestApproval"
let permissions_method = "item/permissions/requestApproval"
let tool_method = "item/tool/call"
let input_method = "item/tool/requestUserInput"
let elicitation_method = "mcpServer/elicitation/request"
let auth_method = "account/chatgptAuthTokens/refresh"
let attestation_method = "attestation/generate"
let legacy_exec_method = "execCommandApproval"
let legacy_patch_method = "applyPatchApproval"
let thread_key = "thread"
let thread_id_key = "threadId"
let turn_key = "turn"
let turn_id_key = "turnId"
let id_key = "id"
let cwd_key = "cwd"
let approval_key = "approvalPolicy"
let reviewer_key = "approvalsReviewer"
let user_reviewer = "user"
let sandbox_key = "sandbox"
let sandbox_policy_key = "sandboxPolicy"
let type_key = "type"
let error_key = "error"
let message_key = "message"
let model_key = "model"
let model_provider_key = "modelProvider"
let item_id_key = "itemId"
let call_id_key = "callId"
let timestamp_key = "startedAtMs"
let parameters_key = "params"
let max_method_bytes = 256
let max_tool_bytes = 256
let method_not_found_code = -32601L
let min_int32 = -2147483648L
let max_int32 = 2147483647L
let max_uint16 = 65535L
let invalid field = Error (Invalid field)

let checked_json value =
  Result.map_error (fun _ -> Invalid "JSON encoding") (Json.of_view value)

let json_string value = checked_json (Json.String value)
let json_bool value = checked_json (Json.Bool value)
let json_object fields = checked_json (Json.Object fields)
let json_array values = checked_json (Json.Array values)

let as_object field value =
  match Json.view value with
  | Json.Object fields -> Ok fields
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _ ->
      invalid field

let as_string field value =
  match Json.view value with
  | Json.String value -> Ok value
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      invalid field

let as_nonempty field value =
  let* value = as_string field value in
  if value = "" then invalid field else Ok value

let as_bool field value =
  match Json.view value with
  | Json.Bool value -> Ok value
  | Json.Null | Json.Number _ | Json.String _ | Json.Array _ | Json.Object _ ->
      invalid field

let as_array field value =
  match Json.view value with
  | Json.Array values -> Ok values
  | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _ ->
      invalid field

let as_int64 field value =
  match Protocol_id.decode value with
  | Ok value -> (
      match Protocol_id.view value with
      | Protocol_id.Integer value -> Ok value
      | Protocol_id.String _ -> invalid field)
  | Error _ -> invalid field

let as_int32 field value =
  let* value = as_int64 field value in
  if value < min_int32 || value > max_int32 then invalid field else Ok value

let as_uint64 field value =
  let* decimal =
    match Json.view value with
    | Json.Number value -> Ok value
    | Json.Null | Json.Bool _ | Json.String _ | Json.Array _ | Json.Object _ ->
        invalid field
  in
  match Count.parse decimal with
  | Ok value when Option.is_some (Count.to_uint64_bits value) -> Ok value
  | Ok _ | Error _ -> invalid field

let as_count field value =
  let* value = as_int64 field value in
  if value < 0L then invalid field else Ok (Count.of_uint64_bits value)

let field fields key =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> invalid key

let required parse fields key =
  let* value = field fields key in
  parse key value

let optional parse fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some value -> (
      match Json.view value with
      | Json.Null -> Ok None
      | Json.Bool _
      | Json.Number _
      | Json.String _
      | Json.Array _
      | Json.Object _ -> Result.map Option.some (parse key value))

let when_present parse fields key =
  match List.assoc_opt key fields with
  | None -> Ok ()
  | Some value -> Result.map (fun _ -> ()) (parse key value)

let nullable parse fields key =
  Result.map (fun _ -> ()) (optional parse fields key)

let each parse values =
  List.fold_left
    (fun result value ->
      let* () = result in
      parse value)
    (Ok ()) values

let strings field value =
  let* values = as_array field value in
  each (fun value -> Result.map (fun _ -> ()) (as_string field value)) values

let required_strings fields names =
  each
    (fun key -> Result.map (fun _ -> ()) (required as_string fields key))
    names

let optional_strings fields names = each (nullable as_string fields) names

let enum choices field value =
  let* text = as_string field value in
  if List.mem text choices then Ok text else invalid field

let absolute field value =
  let* text = as_string field value in
  match Absolute_path.parse text with
  | Ok _ -> Ok text
  | Error _ -> invalid field

let thread_id field value =
  let* text = as_string field value in
  Result.map_error (fun _ -> Invalid field) (Thread_id.parse text)

let turn_id field value =
  let* text = as_string field value in
  Result.map_error (fun _ -> Invalid field) (Turn_id.parse text)

let checked_name field ceiling name =
  if name = "" || String.length name > ceiling || not (Text.valid_utf8 name)
  then invalid field
  else Ok name

let check_method name = checked_name "method" max_method_bytes name

let method_name = function
  | Initialize _ -> initialize_method
  | Start_thread _ -> thread_start_method
  | Name_thread _ -> thread_name_method
  | Start_turn _ -> turn_start_method
  | Interrupt _ -> turn_interrupt_method

let check_definition definition key value =
  Result.map_error
    (fun _ -> Invalid key)
    (Policy_check.validate ~definition value)

let approval_names =
  [
    "mcp_elicitations";
    "request_permissions";
    "rules";
    "sandbox_approval";
    "skill_approval";
  ]

let normalize_approval value =
  let* () = check_definition "AskForApproval" approval_key value in
  match Json.view value with
  | Json.String _ -> Ok value
  | Json.Object fields ->
      let* granular = required as_object fields "granular" in
      let* default = json_bool false in
      (* Compare generated defaults, not omitted-field spelling. *)
      let fields =
        List.map
          (fun key ->
            (key, Option.value (List.assoc_opt key granular) ~default))
          approval_names
      in
      let* granular = json_object fields in
      json_object [ ("granular", granular) ]
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ ->
      invalid approval_key

let normalize_roots value =
  let* values = as_array "writableRoots" value in
  let* paths =
    List.fold_left
      (fun result value ->
        let* paths = result in
        let* path = absolute "writableRoots" value in
        Ok (path :: paths))
      (Ok []) values
  in
  let* paths =
    List.fold_left
      (fun result path ->
        let* values = result in
        let* path = json_string path in
        Ok (path :: values))
      (Ok [])
      (List.sort_uniq String.compare paths)
  in
  json_array paths

let normalize_sandbox value =
  let* () = check_definition "SandboxPolicy" sandbox_policy_key value in
  let* fields = as_object sandbox_policy_key value in
  let* kind = field fields type_key in
  let* kind_name = as_string type_key kind in
  let* disabled = json_bool false in
  let* empty_roots = json_array [] in
  let* restricted = json_string "restricted" in
  let default key fallback =
    (key, Option.value (List.assoc_opt key fields) ~default:fallback)
  in
  let* policy =
    match kind_name with
    | "dangerFullAccess" -> Ok []
    | "readOnly" -> Ok [ default "networkAccess" disabled ]
    | "externalSandbox" -> Ok [ default "networkAccess" restricted ]
    | "workspaceWrite" ->
        let* roots =
          normalize_roots
            (Option.value
               (List.assoc_opt "writableRoots" fields)
               ~default:empty_roots)
        in
        Ok
          [
            ("writableRoots", roots);
            default "networkAccess" disabled;
            default "excludeSlashTmp" disabled;
            default "excludeTmpdirEnvVar" disabled;
          ]
    | _ -> invalid sandbox_policy_key
  in
  json_object ((type_key, kind) :: policy)

let thread_policy value =
  let* fields = as_object "thread policy" value in
  let* approval = field fields approval_key in
  let* _ = normalize_approval approval in
  let* sandbox = field fields sandbox_key in
  let* () = check_definition "SandboxMode" sandbox_key sandbox in
  Ok (approval, sandbox)

let turn_policy value =
  let* fields = as_object "turn policy" value in
  let* approval = field fields approval_key in
  let* _ = normalize_approval approval in
  let* sandbox = field fields sandbox_policy_key in
  let* _ = normalize_sandbox sandbox in
  Ok (approval, sandbox)

let check_turn_policy ~expected ~approval ~sandbox =
  let* expected_approval, expected_sandbox = turn_policy expected in
  let* expected_approval = normalize_approval expected_approval in
  let* expected_sandbox = normalize_sandbox expected_sandbox in
  let* approval = normalize_approval approval in
  let* sandbox = normalize_sandbox sandbox in
  if
    Json.equal approval expected_approval && Json.equal sandbox expected_sandbox
  then Ok ()
  else invalid "effective policy disagreement"

let initialize_params version =
  let* name = json_string "symphony" in
  let* version = json_string version in
  let* client = json_object [ ("name", name); ("version", version) ] in
  let* disabled = json_bool false in
  let* enabled = json_bool true in
  let* capabilities =
    json_object
      [
        ("experimentalApi", disabled);
        ("explicitGatewayOauth", enabled);
        ("requestAttestation", disabled);
      ]
  in
  json_object [ ("clientInfo", client); ("capabilities", capabilities) ]

let checked_cwd cwd =
  let* value = json_string cwd in
  let* _ = absolute cwd_key value in
  Ok value

let request ~id call =
  let* params =
    match call with
    | Initialize { version } -> initialize_params version
    | Start_thread { cwd; policy } ->
        let* approval, sandbox = thread_policy policy in
        let* cwd = checked_cwd cwd in
        let* reviewer = json_string user_reviewer in
        json_object
          [
            (approval_key, approval);
            (sandbox_key, sandbox);
            (cwd_key, cwd);
            (reviewer_key, reviewer);
          ]
    | Name_thread { thread; name } ->
        let* thread = json_string (Thread_id.text thread) in
        let* name = json_string name in
        json_object [ (thread_id_key, thread); ("name", name) ]
    | Start_turn { thread; cwd; policy; prompt } ->
        let* approval, sandbox = turn_policy policy in
        let* thread = json_string (Thread_id.text thread) in
        let* cwd = checked_cwd cwd in
        let* reviewer = json_string user_reviewer in
        let* kind = json_string "text" in
        let* prompt = json_string prompt in
        let* input = json_object [ (type_key, kind); ("text", prompt) ] in
        let* input = json_array [ input ] in
        json_object
          [
            (thread_id_key, thread);
            (cwd_key, cwd);
            (approval_key, approval);
            (reviewer_key, reviewer);
            (sandbox_policy_key, sandbox);
            ("input", input);
          ]
    | Interrupt { thread; turn } ->
        let* thread = json_string (Thread_id.text thread) in
        let* turn = json_string (Turn_id.text turn) in
        json_object [ (thread_id_key, thread); (turn_id_key, turn) ]
  in
  Result.map_error
    (fun error -> Envelope error)
    (Protocol_envelope.request ~id ~method_:(method_name call)
       ~params:(Some params))

let initialized () =
  Result.map_error
    (fun error -> Envelope error)
    (Protocol_envelope.notification ~method_:initialized_method ~params:None)

let known_methods =
  [
    initialize_method;
    initialized_method;
    thread_start_method;
    thread_name_method;
    turn_start_method;
    turn_interrupt_method;
    turn_started_method;
    turn_completed_method;
    usage_method;
    rate_method;
    resolved_method;
    settings_method;
    error_method;
    command_method;
    file_method;
    permissions_method;
    tool_method;
    input_method;
    elicitation_method;
    auth_method;
    attestation_method;
    legacy_exec_method;
    legacy_patch_method;
  ]

let diagnostic_site name =
  let name = if List.mem name known_methods then name else "unrecognized" in
  Diagnostic.Protocol { method_name = name; request_id = None }

let diagnostic ~method_name error =
  let message =
    match error with
    | Invalid _ -> "Invalid Codex protocol data"
    | Envelope _ -> "Invalid Codex protocol envelope"
    | Rpc code -> "Codex RPC failed with code " ^ Int64.to_string code
  in
  Diagnostic.make
    ~site:(diagnostic_site method_name)
    ~message
    ~remedy:
      "Check the accepted Codex protocol, runtime policy, and authentication."

let error_classes =
  [
    "contextWindowExceeded";
    "sessionBudgetExceeded";
    "usageLimitExceeded";
    "rateLimitExceeded";
    "flexUnavailable";
    "serverOverloaded";
    "cyberPolicy";
    "misalignmentPolicyViolation";
    "tooManyDenials";
    "internalServerError";
    "unauthorized";
    "badRequest";
    "threadRollbackFailed";
    "sandboxError";
    "other";
  ]

let http_error_classes =
  [
    "httpConnectionFailed";
    "responseStreamConnectionFailed";
    "responseStreamDisconnected";
    "responseTooManyFailedAttempts";
  ]

let http_status field value =
  let* value = as_int64 field value in
  if value < 0L || value > max_uint16 then invalid field else Ok value

let error_class value =
  match Json.view value with
  | Json.String _ -> enum error_classes "codexErrorInfo" value
  | Json.Object [ (name, value) ] when List.mem name http_error_classes ->
      let* fields = as_object "codexErrorInfo" value in
      let* () = nullable http_status fields "httpStatusCode" in
      Ok name
  | Json.Object [ ("activeTurnNotSteerable", value) ] ->
      let* fields = as_object "codexErrorInfo" value in
      let* _ = required (enum [ "review"; "compact" ]) fields "turnKind" in
      Ok "activeTurnNotSteerable"
  | Json.Null | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      invalid "codexErrorInfo"

let remote_error ~method_name value =
  let* fields = as_object error_key value in
  let* _ = required as_string fields message_key in
  let* () = nullable as_string fields "additionalDetails" in
  let* class_ = optional (fun _ -> error_class) fields "codexErrorInfo" in
  (* Remote prose is untrusted; retain only fixed protocol classes. *)
  let message =
    match class_ with
    | None -> "Codex reported a turn error"
    | Some class_ -> "Codex reported a turn error: " ^ class_
  in
  Ok
    (Diagnostic.make
       ~site:(diagnostic_site method_name)
       ~message
       ~remedy:
         "Check Codex authentication, limits, and the accepted runtime policy.")

let turn ~method_name value =
  let* fields = as_object turn_key value in
  let* id = required turn_id fields id_key in
  let* _ = required as_array fields "items" in
  let* status = required as_string fields "status" in
  let* status =
    match status with
    | "inProgress" -> Ok In_progress
    | "completed" -> Ok Completed
    | "failed" -> Ok Failed
    | "interrupted" -> Ok Interrupted
    | _ -> invalid "status"
  in
  let* () =
    each (nullable as_int64 fields) [ "startedAt"; "completedAt"; "durationMs" ]
  in
  let* error = optional (fun _ -> remote_error ~method_name) fields error_key in
  Ok { id; status; error }

let reviewer fields =
  let* value = required as_string fields reviewer_key in
  if value = user_reviewer then Ok () else invalid reviewer_key

let thread_reply cwd policy fields =
  let* expected_approval, expected_sandbox = thread_policy policy in
  let* approval = field fields approval_key in
  let* expected_approval = normalize_approval expected_approval in
  let* actual_approval = normalize_approval approval in
  if not (Json.equal expected_approval actual_approval) then
    invalid approval_key
  else
    let* () = reviewer fields in
    let* returned_cwd = required absolute fields cwd_key in
    let* () = required_strings fields [ model_key; model_provider_key ] in
    let* sandbox = field fields sandbox_key in
    let* _ = normalize_sandbox sandbox in
    let* sandbox_fields = as_object sandbox_key sandbox in
    let* actual_kind = required as_string sandbox_fields type_key in
    let* expected_mode = as_string sandbox_key expected_sandbox in
    let expected_kind =
      match expected_mode with
      | "read-only" -> "readOnly"
      | "workspace-write" -> "workspaceWrite"
      | "danger-full-access" -> "dangerFullAccess"
      | _ -> ""
    in
    let* thread = required as_object fields thread_key in
    let* thread_cwd = required absolute thread cwd_key in
    let* id = required thread_id thread id_key in
    if returned_cwd <> cwd || thread_cwd <> cwd then invalid cwd_key
    else if actual_kind <> expected_kind then invalid sandbox_key
    else Ok (Thread_started id)

let reply call value =
  let* fields = as_object "reply" value in
  match call with
  | Initialize _ ->
      let* () =
        required_strings fields [ "userAgent"; "platformFamily"; "platformOs" ]
      in
      let* _ = required absolute fields "codexHome" in
      Ok Initialized
  | Start_thread { cwd; policy } -> thread_reply cwd policy fields
  | Name_thread _ -> Ok Named
  | Start_turn _ ->
      let* value = field fields turn_key in
      Result.map
        (fun turn -> Turn_started turn)
        (turn ~method_name:turn_start_method value)
  | Interrupt _ -> Ok Interrupt_ack

let breakdown field_name value =
  let* fields = as_object field_name value in
  let* input = required as_count fields "inputTokens" in
  let* output = required as_count fields "outputTokens" in
  let* total = required as_count fields "totalTokens" in
  let* _ = required as_count fields "cachedInputTokens" in
  let* _ = required as_count fields "reasoningOutputTokens" in
  let* () = when_present as_count fields "cacheWriteInputTokens" in
  Ok (Usage.make ~input ~output ~total)

let usage fields =
  let* thread = required thread_id fields thread_id_key in
  let* turn = required turn_id fields turn_id_key in
  let* tokens = required as_object fields "tokenUsage" in
  (* Validate both reports, then expose the absolute thread watermark. *)
  let* _ = required breakdown tokens "last" in
  let* absolute = required breakdown tokens "total" in
  let* () = nullable as_int64 tokens "modelContextWindow" in
  Ok (Usage { thread; turn; absolute })

let rate_window field_name value =
  let* fields = as_object field_name value in
  let* _ = required as_int32 fields "usedPercent" in
  let* () = nullable as_int64 fields "resetsAt" in
  nullable as_int64 fields "windowDurationMins"

let credits field_name value =
  let* fields = as_object field_name value in
  let* _ = required as_bool fields "hasCredits" in
  let* _ = required as_bool fields "unlimited" in
  nullable as_string fields "balance"

let individual_limit field_name value =
  let* fields = as_object field_name value in
  let* () = required_strings fields [ "limit"; "used" ] in
  let* _ = required as_int32 fields "remainingPercent" in
  Result.map (fun _ -> ()) (required as_int64 fields "resetsAt")

let plans =
  [
    "free";
    "go";
    "plus";
    "pro";
    "prolite";
    "promax";
    "team";
    "self_serve_business_prolite";
    "self_serve_business_usage_based";
    "business";
    "ent26";
    "enterprise_cbp_automation";
    "enterprise_cbp_usage_based";
    "enterprise";
    "edu";
    "edu_plus";
    "edu_pro";
    "unknown";
  ]

let rate_reasons =
  [
    "rate_limit_reached";
    "workspace_owner_credits_depleted";
    "workspace_member_credits_depleted";
    "workspace_owner_usage_limit_reached";
    "workspace_member_usage_limit_reached";
  ]

let rate_limits fields =
  let* value = field fields "rateLimits" in
  let* snapshot = as_object "rateLimits" value in
  let* () = each (nullable rate_window snapshot) [ "primary"; "secondary" ] in
  let* () = nullable credits snapshot "credits" in
  let* () = nullable individual_limit snapshot "individualLimit" in
  let* () =
    optional_strings snapshot [ "limitId"; "limitName"; "normalModelSlug" ]
  in
  let* () = nullable (enum plans) snapshot "planType" in
  let* () = nullable (enum rate_reasons) snapshot "rateLimitReachedType" in
  let* () = nullable as_bool snapshot "spendControlReached" in
  Ok (Rate_limits value)

let collaboration field_name value =
  let* fields = as_object field_name value in
  let* _ = required (enum [ "plan"; "default" ]) fields "mode" in
  let* settings = required as_object fields "settings" in
  let* _ = required as_string settings model_key in
  let* () = nullable as_nonempty settings "reasoning_effort" in
  nullable as_string settings "developer_instructions"

let active_profile field_name value =
  let* fields = as_object field_name value in
  let* _ = required as_string fields id_key in
  nullable as_string fields "extends"

let settings fields =
  let* thread = required thread_id fields thread_id_key in
  let* fields = required as_object fields "threadSettings" in
  let* approval = field fields approval_key in
  let* _ = normalize_approval approval in
  let* sandbox = field fields sandbox_policy_key in
  let* _ = normalize_sandbox sandbox in
  let* cwd = required absolute fields cwd_key in
  let* () = reviewer fields in
  let* () = required_strings fields [ model_key; model_provider_key ] in
  let* () = required collaboration fields "collaborationMode" in
  let* () = when_present strings fields "disabledPluginIds" in
  let* () = nullable active_profile fields "activePermissionProfile" in
  let* () = nullable as_nonempty fields "effort" in
  let* () =
    nullable (enum [ "none"; "friendly"; "pragmatic" ]) fields "personality"
  in
  let* () = nullable as_string fields "serviceTier" in
  let* () =
    nullable (enum [ "auto"; "concise"; "detailed"; "none" ]) fields "summary"
  in
  Ok (Settings { thread; cwd; approval; sandbox })

let params method_name = function
  | Some value -> as_object parameters_key value
  | None -> invalid method_name

let observational ~method_name value =
  let* thread, turn =
    match value with
    | Some value -> (
        match Json.view value with
        | Json.Object fields ->
            let* thread = optional thread_id fields thread_id_key in
            let* turn = optional turn_id fields turn_id_key in
            Ok (thread, turn)
        | Json.Null | Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          -> Ok (None, None))
    | None -> Ok (None, None)
  in
  Ok (Other { method_name; thread; turn })

let notification ~method_name value =
  let* _ = check_method method_name in
  if method_name = turn_started_method || method_name = turn_completed_method
  then
    let* fields = params method_name value in
    let* thread = required thread_id fields thread_id_key in
    let* value = field fields turn_key in
    let* turn = turn ~method_name value in
    if method_name = turn_started_method then
      Ok (Turn_started_notice { thread; turn })
    else Ok (Turn_completed_notice { thread; turn })
  else if method_name = usage_method then
    let* fields = params method_name value in
    usage fields
  else if method_name = rate_method then
    let* fields = params method_name value in
    rate_limits fields
  else if method_name = resolved_method then
    let* fields = params method_name value in
    let* thread = required thread_id fields thread_id_key in
    let* value = field fields "requestId" in
    let* request =
      Result.map_error (fun _ -> Invalid "requestId") (Protocol_id.decode value)
    in
    Ok (Request_resolved { thread; request })
  else if method_name = settings_method then
    let* fields = params method_name value in
    settings fields
  else if method_name = error_method then
    let* fields = params method_name value in
    let* thread = required thread_id fields thread_id_key in
    let* turn = required turn_id fields turn_id_key in
    let* _ = required as_bool fields "willRetry" in
    let* value = field fields error_key in
    let* _ = remote_error ~method_name value in
    Ok (Other { method_name; thread = Some thread; turn = Some turn })
  else observational ~method_name value

let current_context fields =
  let* thread = required thread_id fields thread_id_key in
  let* turn = required turn_id fields turn_id_key in
  Ok { thread = Some thread; turn = Some turn }

let legacy_context fields =
  let* thread = required thread_id fields "conversationId" in
  Ok { thread = Some thread; turn = None }

let approval_context fields =
  let* context = current_context fields in
  let* _ = required as_string fields item_id_key in
  let* _ = required as_int64 fields timestamp_key in
  Ok context

let tool_context fields =
  let* context = current_context fields in
  let* _ = required as_string fields call_id_key in
  let* _ = field fields "arguments" in
  let* name = required as_string fields "tool" in
  let* name = checked_name "tool" max_tool_bytes name in
  let* () = nullable as_string fields "namespace" in
  Ok (context, name)

let question value =
  let* fields = as_object "questions" value in
  let* () = required_strings fields [ "header"; id_key; "question" ] in
  let* () = each (when_present as_bool fields) [ "isOther"; "isSecret" ] in
  let check_options field_name value =
    let* values = as_array field_name value in
    each
      (fun value ->
        let* fields = as_object field_name value in
        required_strings fields [ "label"; "description" ])
      values
  in
  nullable check_options fields "options"

let input_context fields =
  let* context = current_context fields in
  let* _ = required as_string fields item_id_key in
  let* _ = required as_bool fields "isBlocking" in
  let* questions = required as_array fields "questions" in
  let* () = each question questions in
  let* () = nullable as_uint64 fields "autoResolutionMs" in
  Ok context

let permissions_shape fields =
  let* _ = required as_string fields cwd_key in
  let* profile = required as_object fields "permissions" in
  if
    List.exists
      (fun (key, _) -> key <> "fileSystem" && key <> "network")
      profile
  then invalid "permissions"
  else
    let check_network field_name value =
      let* fields = as_object field_name value in
      nullable as_bool fields "enabled"
    in
    let check_files field_name value =
      let* fields = as_object field_name value in
      let* () = each (nullable strings fields) [ "read"; "write" ] in
      let* () = nullable as_array fields "entries" in
      let check_depth field_name value =
        let* value = as_uint64 field_name value in
        if Count.compare value Count.zero <= 0 then invalid field_name
        else Ok ()
      in
      nullable check_depth fields "globScanMaxDepth"
    in
    let* () = nullable check_network profile "network" in
    nullable check_files profile "fileSystem"

let elicitation_context fields =
  let* thread = required thread_id fields thread_id_key in
  let* turn = optional turn_id fields turn_id_key in
  let* () = required_strings fields [ "serverName"; message_key ] in
  let* mode = required as_string fields "mode" in
  let* () =
    match mode with
    | "form" ->
        let* schema = required as_object fields "requestedSchema" in
        let* _ = required (enum [ "object" ]) schema type_key in
        let* _ = required as_object schema "properties" in
        let* () = nullable strings schema "required" in
        nullable as_string schema "$schema"
    | "openai/form" | "openaiForm" ->
        Result.map (fun _ -> ()) (field fields "requestedSchema")
    | "url" -> required_strings fields [ "elicitationId"; "url" ]
    | _ -> invalid "mode"
  in
  Ok { thread = Some thread; turn }

let parsed_command value =
  let* fields = as_object "parsedCmd" value in
  let* kind = required as_string fields type_key in
  let* _ = required as_string fields "cmd" in
  match kind with
  | "read" -> required_strings fields [ "name"; "path" ]
  | "list_files" -> nullable as_string fields "path"
  | "search" -> optional_strings fields [ "path"; "query" ]
  | "unknown" -> Ok ()
  | _ -> invalid "parsedCmd"

let file_change value =
  let* fields = as_object "fileChanges" value in
  let* kind = required as_string fields type_key in
  match kind with
  | "add" | "delete" ->
      Result.map (fun _ -> ()) (required as_string fields "content")
  | "update" ->
      let* _ = required as_string fields "unified_diff" in
      nullable as_string fields "move_path"
  | _ -> invalid "fileChanges"

let server_response id result =
  Result.map_error
    (fun error -> Envelope error)
    (Protocol_envelope.response ~id ~reply:(Protocol_envelope.Success result))

let unsupported_response id =
  let error =
    Protocol_envelope.Failure
      {
        Protocol_envelope.code = method_not_found_code;
        Protocol_envelope.message = "Unsupported method";
        Protocol_envelope.data = None;
      }
  in
  Result.map_error
    (fun error -> Envelope error)
    (Protocol_envelope.response ~id ~reply:error)

let decline id =
  let* decision = json_string "decline" in
  let* result = json_object [ ("decision", decision) ] in
  server_response id result

let legacy_denial id =
  let* rejection = json_string "Unattended policy denies approval" in
  let* denial = json_object [ ("rejection", rejection) ] in
  let* decision = json_object [ ("denied", denial) ] in
  let* result = json_object [ ("decision", decision) ] in
  server_response id result

let permission_denial id =
  let* permissions = json_object [] in
  let* scope = json_string "turn" in
  let* result =
    json_object [ ("permissions", permissions); ("scope", scope) ]
  in
  server_response id result

let tool_denial id =
  let* kind = json_string "inputText" in
  let* text = json_string "Unsupported tool" in
  let* content = json_object [ (type_key, kind); ("text", text) ] in
  let* contents = json_array [ content ] in
  let* success = json_bool false in
  let* result =
    json_object [ ("success", success); ("contentItems", contents) ]
  in
  server_response id result

let elicitation_cancel id =
  let* action = json_string "cancel" in
  let* content = checked_json Json.Null in
  let* result = json_object [ ("action", action); ("content", content) ] in
  server_response id result

type server_kind =
  | Command
  | File
  | Permissions
  | Tool
  | Input
  | Elicitation
  | Auth
  | Attestation
  | Legacy_exec
  | Legacy_patch

let server_methods =
  [
    (command_method, Command);
    (file_method, File);
    (permissions_method, Permissions);
    (tool_method, Tool);
    (input_method, Input);
    (elicitation_method, Elicitation);
    (auth_method, Auth);
    (attestation_method, Attestation);
    (legacy_exec_method, Legacy_exec);
    (legacy_patch_method, Legacy_patch);
  ]

let server_request ~id ~method_name value =
  let* _ = check_method method_name in
  match List.assoc_opt method_name server_methods with
  | None ->
      let* response = unsupported_response id in
      Ok
        (Reply
           { context = { thread = None; turn = None }; response; tool = None })
  | Some kind -> (
      let* fields = params method_name value in
      match kind with
      | Command ->
          let* context = approval_context fields in
          let* () =
            optional_strings fields
              [ "approvalId"; "command"; cwd_key; "reason"; "environmentId" ]
          in
          let* () =
            when_present (enum [ "command"; "writeStdin" ]) fields "kind"
          in
          let* () = nullable strings fields "proposedExecpolicyAmendment" in
          let* response = decline id in
          Ok (Reply { context; response; tool = None })
      | File ->
          let* context = approval_context fields in
          let* () = optional_strings fields [ "reason"; "grantRoot" ] in
          let* response = decline id in
          Ok (Reply { context; response; tool = None })
      | Permissions ->
          let* context = approval_context fields in
          let* () = permissions_shape fields in
          let* () = optional_strings fields [ "reason"; "environmentId" ] in
          let* response = permission_denial id in
          Ok (Reply { context; response; tool = None })
      | Tool ->
          let* context, tool = tool_context fields in
          let* response = tool_denial id in
          Ok (Reply { context; response; tool = Some tool })
      | Input ->
          let* context = input_context fields in
          Ok (Input_required { context; response = None })
      | Elicitation ->
          let* context = elicitation_context fields in
          let* response = elicitation_cancel id in
          Ok (Input_required { context; response = Some response })
      | Auth ->
          let* _ = required (enum [ "unauthorized" ]) fields "reason" in
          let* () = nullable as_string fields "previousAccountId" in
          let* response = unsupported_response id in
          Ok (Unsupported response)
      | Attestation ->
          let* response = unsupported_response id in
          Ok (Unsupported response)
      | Legacy_exec ->
          let* context = legacy_context fields in
          let* () = required_strings fields [ call_id_key; cwd_key ] in
          let* command = field fields "command" in
          let* () = strings "command" command in
          let* parsed = required as_array fields "parsedCmd" in
          let* () = each parsed_command parsed in
          let* () = optional_strings fields [ "approvalId"; "reason" ] in
          let* response = legacy_denial id in
          Ok (Reply { context; response; tool = None })
      | Legacy_patch ->
          let* context = legacy_context fields in
          let* _ = required as_string fields call_id_key in
          let* changes = required as_object fields "fileChanges" in
          let* () = each (fun (_, change) -> file_change change) changes in
          let* () = optional_strings fields [ "reason"; "grantRoot" ] in
          let* response = legacy_denial id in
          Ok (Reply { context; response; tool = None }))
