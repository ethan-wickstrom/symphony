let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let path value = checked (Absolute_path.parse value)
let json value = checked (Json.parse value)
let config value = checked (Config_value.parse value)

let raw ?(temp = "/host/temp") bindings =
  checked (Environment.of_bindings ~temp_dir:(path temp) bindings)

let public ?(deny = [ "TOKEN" ]) ?(secrets = []) bindings =
  Environment.public (raw bindings) ~deny
    ~secrets:(List.filter_map Environment.Secret.make secrets)

let secret value = public [ ("TOKEN", value) ]

let message =
  "value selects a quarantined credential; use a public value or variable"

let rejected = function
  | Error actual -> Alcotest.(check string) "redacted remedy" message actual
  | Ok _ -> Alcotest.fail "credential material accepted in a public field"

let contains text part =
  let span = String.length text - String.length part in
  span >= 0
  && Seq.exists
       (fun offset -> String.sub text offset (String.length part) = part)
       (Seq.init (span + 1) Fun.id)

let config_rejected token = function
  | Ok _ -> Alcotest.fail "credential material accepted by core settings"
  | Error errors ->
      let rendered =
        String.concat "\n"
          (List.map Diagnostic.render (Nonempty_list.to_list errors))
      in
      Alcotest.(check bool)
        "credential remedy" true
        (contains rendered "quarantined credential");
      Alcotest.(check bool) "token redacted" false (contains rendered token)

let source_alias_literal () =
  let token = "fixture-credential" in
  let env = public [ ("TOKEN", token); ("ALIAS", token); ("SAFE", "public") ] in
  rejected (Environment.lookup_public env "TOKEN");
  rejected (Environment.lookup_public env "ALIAS");
  rejected (Environment.check env token);
  rejected (Fields.text env (config "'$ALIAS'"));
  rejected (Fields.text env (config "'fixture-credential'"));
  Alcotest.(check (option string))
    "public survives" (Some "public")
    (checked (Environment.lookup_public env "SAFE"))

let missing_empty () =
  let env =
    public ~deny:[ "TOKEN"; "ABSENT" ] [ ("TOKEN", ""); ("ALIAS", "") ]
  in
  rejected (Environment.lookup_public env "TOKEN");
  rejected (Environment.lookup_public env "ABSENT");
  Alcotest.(check (option string))
    "unrelated absence" None
    (checked (Environment.lookup_public env "UNSET"));
  Alcotest.(check (option string))
    "empty alias public" (Some "")
    (checked (Environment.lookup_public env "ALIAS"))

let child_aliases () =
  let env =
    public [ ("TOKEN", "secret"); ("PATH", "secret"); ("HOME", "/public") ]
  in
  let allow = [ "PATH"; "TOKEN"; "HOME"; "HOME" ] in
  Alcotest.(check (list (pair string string)))
    "allowlist minus quarantine"
    [ ("HOME", "/public") ]
    (Environment.bindings (Environment.child env ~allow))

let explicit_and_temp () =
  let env =
    public ~deny:[] ~secrets:[ "literal-token" ] [ ("PATH", "literal-token") ]
  in
  rejected (Environment.lookup_public env "PATH");
  rejected (Environment.check env "literal-token");
  let env =
    Environment.public
      (raw ~temp:"/host/temp" [])
      ~deny:[]
      ~secrets:(List.filter_map Environment.Secret.make [ "/host/temp" ])
  in
  rejected (Environment.public_temp_dir env)

let exact_numbers () =
  let env = secret "617283" in
  List.iter
    (fun source -> rejected (Fields.integer env (config source)))
    [ "'+0617283'"; "0x96b43"; "617283" ];
  let reverse = secret "6.17283e5" in
  rejected (Fields.integer reverse (config "617283"));
  List.iter
    (fun encoded -> rejected (Environment.check_json env (json encoded)))
    [ "617283.0"; "6.17283e5"; "617283e0" ];
  Alcotest.(check string)
    "different exact value survives" "617284"
    (Z.to_string (checked (Fields.integer env (config "617284"))))

let json_leaves () =
  let token = "opaque-token" in
  let env = secret token in
  List.iter
    (fun value -> rejected (Environment.check_json env (json value)))
    [
      {|["opaque-token"]|};
      {|{"opaque-token":true}|};
      {|{"nested":["opaque-token"]}|};
    ]

let json_aggregate () =
  let env = secret {|{"count":617283,"ready":true}|} in
  rejected
    (Environment.check_json env (json {|{"ready":true,"count":6.17283e5}|}));
  rejected
    (Environment.check_json env (json {|[{"ready":true,"count":617283}]|}));
  let original = json {|{"ready":false,"count":617284}|} in
  let result = checked (Environment.check_json env original) in
  Alcotest.(check bool)
    "success returns same checked value" true (original == result);
  Alcotest.(check bool)
    "idempotence" true
    (Json.equal result (checked (Environment.check_json env result)))

let fields_json () =
  let env = secret "opaque-token" in
  List.iter
    (fun source -> rejected (Fields.json env (config source)))
    [ "[opaque-token]"; "{opaque-token: true}"; "{root: [opaque-token]}" ];
  rejected (Fields.json (secret "617283") (config "{limit: 6.17283e5}"))

let paths () =
  let root = "/private/workspaces" in
  let env = public [ ("TOKEN", root); ("ALIAS", root); ("HOME", root) ] in
  List.iter
    (fun value -> rejected (Fields.path env ~base:(path "/public") value))
    [ "$TOKEN/x"; "${ALIAS}/x"; root; "/private/x/../workspaces"; "~/repo" ];
  let public_env =
    public [ ("ROOT", "repositories"); ("HOME", "/public/home") ]
  in
  Alcotest.(check string)
    "public path variables" "/public/repositories"
    (Absolute_path.display
       (checked (Fields.path public_env ~base:(path "/public") "$ROOT")))

let missing_name () =
  let token = "SECRET_REF_NAME" in
  let env = secret token in
  rejected (Fields.text env (config "'$SECRET_REF_NAME'"));
  rejected (Fields.path env ~base:(path "/public") "$SECRET_REF_NAME/x");
  match Fields.text env (config "'$PUBLIC_MISSING'") with
  | Ok _ -> Alcotest.fail "missing variable accepted"
  | Error error ->
      Alcotest.(check bool)
        "public missing name remains actionable" true
        (contains error "PUBLIC_MISSING")

let bootstrap_missing () =
  let token = "SECRET_REF_NAME" in
  let env = raw [ ("TOKEN", token) ] in
  match Fields.credential_text env (config "'$SECRET_REF_NAME'") with
  | Ok _ -> Alcotest.fail "missing bootstrap variable accepted"
  | Error error ->
      Alcotest.(check bool)
        "bootstrap missing name redacted" false (contains error token);
      Alcotest.(check bool) "bootstrap remedy" true (contains error "missing")

let schedule = "tracker:\n  active_states: [Todo]\n  terminal_states: [Done]\n"

let normalized_names () =
  config_rejected "done"
    (Scheduling_policy.parse ~env:(secret "done") (config schedule));
  config_rejected "label-secret"
    (Scheduling_policy.parse ~env:(secret "label-secret")
       (config (schedule ^ "  required_labels: [' LABEL-SECRET ']\n")))

let default_root () =
  let token = "/host/temp/symphony_workspaces" in
  let workflow_file =
    checked (Workflow_path.resolve ~base:(path "/public") "WORKFLOW.md")
  in
  config_rejected token
    (Workspace_settings.parse ~env:(secret token) ~workflow_file (config "{}"))

let agent_string () =
  config_rejected {|"never"|}
    (Agent_settings.parse ~env:(secret {|"never"|})
       (config "codex:\n  approval_policy: never\n"))

let agent_assembled () =
  let token = {|{"approvalPolicy":"never","sandbox":"workspace-write"}|} in
  config_rejected token (Agent_settings.parse ~env:(secret token) (config "{}"))

let agent_defaults () =
  List.iter
    (fun token ->
      config_rejected token
        (Agent_settings.parse ~env:(secret token) (config "{}")))
    [ "never"; "workspace-write"; "approvalPolicy" ]

module Path = struct
  type t = string

  let display value = value
end

module Bound = Agent_settings.Bind (Path)

let agent env =
  match Agent_settings.parse ~env (config "{}") with
  | Ok settings -> settings
  | Error _ ->
      Alcotest.fail "unrelated credential prevented policy construction"

let agent_bound () =
  let root = "/public/workspaces/issue" in
  let aggregate =
    {|{"type":"workspaceWrite","writableRoots":["/public/workspaces/issue"],"networkAccess":false,"excludeSlashTmp":true,"excludeTmpdirEnvVar":true}|}
  in
  List.iter
    (fun token ->
      match Bound.turn_policy (agent (secret token)) root with
      | Ok _ ->
          Alcotest.fail "generated workspace policy disclosed a credential"
      | Error error ->
          let rendered = Diagnostic.render error in
          Alcotest.(check bool)
            "generated policy names field" true
            (contains rendered "codex.turn_sandbox_policy");
          Alcotest.(check bool)
            "generated credential redacted" false (contains rendered token))
    [ root; aggregate ];
  match Bound.turn_policy (agent (secret "unrelated-credential")) root with
  | Error error -> Alcotest.fail (Diagnostic.render error)
  | Ok policy ->
      Alcotest.(check bool)
        "public workspace survives binding" true
        (contains (Json.encode policy) root)

let quarantine_equal () =
  let bindings =
    [ ("TOKEN", "credential"); ("ALIAS", "credential"); ("SAFE", "public") ]
  in
  let first =
    public ~deny:[ "TOKEN"; "UNSET" ] ~secrets:[ "literal" ] bindings
  in
  let reordered =
    public
      ~deny:[ "UNSET"; "TOKEN"; "TOKEN" ]
      ~secrets:[ "literal"; "literal" ] (List.rev bindings)
  in
  let a = Environment.quarantine first
  and b = Environment.quarantine reordered in
  Alcotest.(check bool)
    "rules ignore order and duplication" true
    (Environment.Quarantine.equal a b);
  List.iter
    (fun value ->
      Alcotest.(check (result string string))
        "equal rules agree"
        (Environment.Quarantine.check a value)
        (Environment.Quarantine.check b value))
    [ "credential"; "literal"; "public" ];
  Alcotest.(check bool)
    "deferred policy equality observes rules" false
    (Agent_settings.equal
       (agent (secret "credential-a"))
       (agent (secret "credential-b")))

let trusted_shell () =
  let token = "literal-shell" in
  let settings =
    match
      Agent_settings.parse ~env:(secret token)
        (config "codex:\n  command: literal-shell\n")
    with
    | Ok settings -> settings
    | Error _ ->
        Alcotest.fail "trusted shell configuration lost verbatim semantics"
  in
  Alcotest.(check string)
    "trusted literal command" token
    (Agent_settings.command settings)

let sample_count = 1000

let list_model (values, (deny, literals)) =
  let entries =
    List.mapi (fun index value -> ("VAR_" ^ string_of_int index, value)) values
  in
  let tokens =
    List.filter (( <> ) "")
      (literals @ List.filter_map (fun name -> List.assoc_opt name entries) deny)
  in
  let quarantined value = List.mem value tokens in
  let env = public ~deny ~secrets:literals entries in
  let names = "UNSET" :: List.map fst entries in
  let lookup_agrees name =
    let model =
      if List.mem name deny then Error ()
      else
        match List.assoc_opt name entries with
        | None -> Ok None
        | Some value when quarantined value -> Error ()
        | Some value -> Ok (Some value)
    in
    Result.map_error (fun _ -> ()) (Environment.lookup_public env name) = model
  in
  let child =
    List.filter
      (fun (name, value) -> not (List.mem name deny || quarantined value))
      entries
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  let permuted =
    public
      ~deny:(List.rev (deny @ deny))
      ~secrets:(List.rev (literals @ literals))
      entries
  in
  List.for_all lookup_agrees names
  && Environment.bindings (Environment.child env ~allow:(names @ names)) = child
  && List.for_all
       (fun name ->
         Environment.lookup_public env name
         = Environment.lookup_public permuted name)
       names

let generator =
  let open QCheck2.Gen in
  let value =
    oneof_list [ ""; "public"; "credential-a"; "credential-b"; "17" ]
  in
  pair
    (list_size (int_range 0 20) value)
    (pair
       (list_size (int_range 0 12)
          (oneof_list [ "VAR_0"; "VAR_1"; "VAR_2"; "VAR_5"; "UNSET" ]))
       (list_size (int_range 0 8) value))

let numeric_alias number =
  let canonical = string_of_int number in
  let env = secret canonical in
  let aliases = [ canonical ^ ".00"; canonical ^ "e0"; canonical ^ "0e-1" ] in
  List.for_all
    (fun value -> Result.is_error (Environment.check_json env (json value)))
    aliases

let tests =
  [
    Alcotest.test_case "sources aliases and literals are quarantined" `Quick
      source_alias_literal;
    Alcotest.test_case "absence and empty secrets stay distinct" `Quick
      missing_empty;
    Alcotest.test_case "child aliases cannot disclose credentials" `Quick
      child_aliases;
    Alcotest.test_case "explicit credentials and temp path are guarded" `Quick
      explicit_and_temp;
    Alcotest.test_case "exact integers and JSON numeric aliases are guarded"
      `Quick exact_numbers;
    Alcotest.test_case "JSON leaves and keys are guarded" `Quick json_leaves;
    Alcotest.test_case "nested JSON equivalence and retraction" `Quick
      json_aggregate;
    Alcotest.test_case "Fields JSON guards nested values" `Quick fields_json;
    Alcotest.test_case "paths guard lookup literals and canonical output" `Quick
      paths;
    Alcotest.test_case "missing variable names cannot disclose credentials"
      `Quick missing_name;
    Alcotest.test_case "bootstrap missing reference redacts its source name"
      `Quick bootstrap_missing;
    Alcotest.test_case "normalized core names remain guarded" `Quick
      normalized_names;
    Alcotest.test_case "derived default workspace root is guarded" `Quick
      default_root;
    Alcotest.test_case "agent string policy guards JSON equivalence" `Quick
      agent_string;
    Alcotest.test_case "assembled agent thread policy is guarded" `Quick
      agent_assembled;
    Alcotest.test_case "default agent constants and keys are guarded" `Quick
      agent_defaults;
    Alcotest.test_case "generated workspace policy retains only quarantine"
      `Quick agent_bound;
    Alcotest.test_case "quarantine equality preserves deferred behavior" `Quick
      quarantine_equal;
    Alcotest.test_case "trusted shell literal remains verbatim" `Quick
      trusted_shell;
  ]

let properties =
  [
    QCheck2.Test.make ~name:"environment quarantine agrees with list model"
      ~count:sample_count generator list_model;
    QCheck2.Test.make
      ~name:"JSON numeric equivalence is closed under quarantine"
      ~count:sample_count
      QCheck2.Gen.(int_range 1 1000000)
      numeric_alias;
  ]
