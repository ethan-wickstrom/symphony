let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let path text = checked (Absolute_path.parse text)

let file =
  checked
    (Workflow_path.resolve ~base:(path "/srv/symphony/workflows") "WORKFLOW.md")

let environment bindings =
  checked (Environment.of_bindings ~temp_dir:(path "/host/temp") bindings)

let env =
  environment
    [
      ("HOME", "/home/operator");
      ("LINEAR_API_KEY", "fixture-secret");
      ("WORK_ROOT", "repositories");
      ("POLL_MS", "17");
    ]

let base =
  "tracker:\n\
  \  kind: linear\n\
  \  active_states: [Todo, 'In Progress']\n\
  \  terminal_states: [Done, Canceled]\n\
  \  provider:\n\
  \    project_slug: fixture-project\n"

let diagnostics errors =
  String.concat "\n" (List.map Diagnostic.render (Nonempty_list.to_list errors))

let workflow_error = function
  | Workflow_loader.Missing_file d | Workflow_loader.Read_error d ->
      Diagnostic.render d
  | Workflow_loader.Invalid_document
      ( Workflow_document.Parse_error d
      | Workflow_document.Front_matter_not_map d ) -> Diagnostic.render d

let error_text = function
  | Config_layer.Workflow error -> workflow_error error
  | Config_layer.Fields errors -> diagnostics errors
  | Config_layer.Tracker error ->
      Diagnostic.render (Tracker_error.diagnostic error)

let value source = checked (Config_value.parse source)

let schedule ?(environment = env) extra =
  let public =
    Environment.public environment ~deny:[ "LINEAR_API_KEY" ] ~secrets:[]
  in
  match Scheduling_policy.parse ~env:public (value (base ^ extra)) with
  | Ok settings -> settings
  | Error errors -> Alcotest.fail (diagnostics errors)

let names values = Scheduling_policy.Names.elements values
let milliseconds value = Milliseconds.decimal value

type number_form = Decimal | Quoted | Hex | Octal
type load = Valid of int | Invalid_poll | Invalid_turn | Missing_workflow

let print_load = function
  | Valid n -> Printf.sprintf "Valid %d" n
  | Invalid_poll -> "Invalid_poll"
  | Invalid_turn -> "Invalid_turn"
  | Missing_workflow -> "Missing_workflow"

let print_number (n, form) =
  let form =
    match form with
    | Decimal -> "decimal"
    | Quoted -> "quoted"
    | Hex -> "hex"
    | Octal -> "octal"
  in
  Printf.sprintf "(%d, %s)" n form

module Loader_io = struct
  type t = (string, Workflow_loader.error) result

  let read result ~file:_ = result
end

module Loader = Workflow_loader.Make (Loader_io)

module Make (Config : Config_layer.S) = struct
  let resolve registry ?(environment = env) ?(source = file) text =
    let document =
      match Workflow_document.parse ~file:source ("---\n" ^ text ^ "---\n") with
      | Ok document -> document
      | Error
          ( Workflow_document.Parse_error d
          | Workflow_document.Front_matter_not_map d ) ->
          Alcotest.fail (Diagnostic.render d)
    in
    Config.resolve registry ~env:environment ~document

  let configured registry ?environment ?source extra =
    match resolve registry ?environment ?source (base ^ extra) with
    | Ok settings -> settings
    | Error error -> Alcotest.fail (error_text error)

  let rejected registry ?environment text =
    match resolve registry ?environment text with
    | Error error -> error
    | Ok _ -> Alcotest.fail "invalid configuration was accepted"

  let checked_config_env registry environment text =
    match resolve registry ~environment text with
    | Ok settings -> settings
    | Error error -> Alcotest.fail (error_text error)

  let checked_config registry text = checked_config_env registry env text

  let defaults registry () =
    let settings = configured registry "" in
    let policy = Config.scheduling settings in
    Alcotest.(check (list string))
      "active states" [ "in progress"; "todo" ]
      (names (Scheduling_policy.active policy));
    Alcotest.(check (list string))
      "terminal states" [ "canceled"; "done" ]
      (names (Scheduling_policy.terminal policy));
    Alcotest.(check (list string))
      "labels" []
      (names (Scheduling_policy.required_labels policy));
    Alcotest.(check string)
      "poll" "30000"
      (milliseconds (Scheduling_policy.poll_interval policy));
    Alcotest.(check int)
      "global concurrency" 10
      (Scheduling_policy.global_limit policy);
    Alcotest.(check int)
      "unconfigured state" 10
      (Scheduling_policy.state_limit policy "Todo");
    Alcotest.(check string)
      "retry cap" "300000"
      (milliseconds (Scheduling_policy.max_retry_delay policy));
    (match Scheduling_policy.stall policy with
    | Scheduling_policy.Disabled -> Alcotest.fail "default stall limit disabled"
    | Scheduling_policy.Silence_limit limit ->
        Alcotest.(check string) "stall" "300000" (milliseconds limit));
    let workspace = Config.workspace settings in
    Alcotest.(check string)
      "explicit system temp" "/host/temp/symphony_workspaces"
      (Absolute_path.display (Workspace_settings.root workspace));
    Alcotest.(check string)
      "hook timeout" "60000"
      (milliseconds (Workspace_settings.timeout workspace));
    List.iter
      (fun hook ->
        Alcotest.(check (option string))
          "missing hook" None
          (Workspace_settings.script workspace hook))
      [
        Workspace_settings.After_create;
        Workspace_settings.Before_run;
        Workspace_settings.After_run;
        Workspace_settings.Before_remove;
      ];
    let agent = Config.agent settings in
    Alcotest.(check string)
      "command" "codex app-server"
      (Agent_settings.command agent);
    Alcotest.(check int) "max turns" 20 (Agent_settings.max_turns agent);
    Alcotest.(check string)
      "read timeout" "5000"
      (milliseconds (Agent_settings.read_timeout agent));
    Alcotest.(check string)
      "turn timeout" "3600000"
      (milliseconds (Agent_settings.turn_timeout agent));
    Alcotest.(check string)
      "source identity"
      (Workflow_path.display file)
      (Workflow_path.display (Config.file settings));
    Alcotest.(check string)
      "empty prompt fallback"
      "You are working on an issue from the configured tracker."
      (Config.prompt_source settings)

  let path_examples registry () =
    List.iter
      (fun (root, expected) ->
        let settings =
          configured registry ("workspace:\n  root: " ^ root ^ "\n")
        in
        Alcotest.(check string)
          root expected
          (Absolute_path.display
             (Workspace_settings.root (Config.workspace settings))))
      [
        ("'../work/./one/../two'", "/srv/symphony/work/two");
        ("'~/repos'", "/home/operator/repos");
        ( "'$WORK_ROOT/./child/../repo'",
          "/srv/symphony/workflows/repositories/repo" );
        ("'${WORK_ROOT}/repo'", "/srv/symphony/workflows/repositories/repo");
        ("'/var/work/../repos'", "/var/repos");
      ];
    ignore
      (rejected registry (base ^ "workspace:\n  root: '$ABSENT_ROOT/repo'\n"));
    let no_home = environment [ ("LINEAR_API_KEY", "fixture-secret") ] in
    ignore
      (rejected registry ~environment:no_home
         (base ^ "workspace:\n  root: '~/repo'\n"))

  let env_tilde registry () =
    let snapshot =
      environment
        [
          ("LINEAR_API_KEY", "fixture-secret");
          ("HOME", "/home/operator");
          ("ROOT", "~/repos");
        ]
    in
    let settings =
      configured registry ~environment:snapshot "workspace:\n  root: '$ROOT'\n"
    in
    Alcotest.(check string)
      "env-backed tilde" "/home/operator/repos"
      (Absolute_path.display
         (Workspace_settings.root (Config.workspace settings)))

  let literal_home registry () =
    let literal_home =
      environment
        [ ("LINEAR_API_KEY", "fixture-secret"); ("HOME", "/home/$literal") ]
    in
    let settings =
      configured registry ~environment:literal_home
        "workspace:\n  root: '~/repos'\n"
    in
    Alcotest.(check string)
      "HOME contents are literal" "/home/$literal/repos"
      (Absolute_path.display
         (Workspace_settings.root (Config.workspace settings)))

  let invalid_home registry home () =
    let snapshot =
      environment [ ("LINEAR_API_KEY", "fixture-secret"); ("HOME", home) ]
    in
    ignore
      (rejected registry ~environment:snapshot
         (base ^ "workspace:\n  root: '~/repo'\n"))

  let command_examples registry () =
    let command = "printf '$WORK_ROOT ~ $(date)' && codex app-server" in
    let hook = "printf '$WORK_ROOT ~ $(date)'\n" in
    let settings =
      configured registry
        ("codex:\n  command: "
        ^ Printf.sprintf "%S" command
        ^ "\nhooks:\n  before_run: |\n    printf '$WORK_ROOT ~ $(date)'\n")
    in
    Alcotest.(check string)
      "command bytes" command
      (Agent_settings.command (Config.agent settings));
    Alcotest.(check (option string))
      "hook bytes" (Some hook)
      (Workspace_settings.script
         (Config.workspace settings)
         Workspace_settings.Before_run);
    ignore (rejected registry (base ^ "codex:\n  command: ''\n"))

  let numeric_examples registry () =
    List.iter
      (fun (lexeme, expected) ->
        let settings =
          configured registry ("polling:\n  interval_ms: " ^ lexeme ^ "\n")
        in
        Alcotest.(check string)
          lexeme expected
          (milliseconds
             (Scheduling_policy.poll_interval (Config.scheduling settings))))
      [
        ("17", "17");
        ("'+17'", "17");
        ("'0017'", "17");
        ("0x11", "17");
        ("0x1e", "30");
        ("0o21", "17");
        ("'$POLL_MS'", "17");
      ];
    (* YAML 1.2.2 §10.3.2 resolves 1_7 as a string, not an integer.
       Bare and quoted strings therefore obey the same strict decimal rule.
       https://yaml.org/spec/1.2.2/#1032-tag-resolution *)
    List.iter
      (fun lexeme ->
        ignore
          (rejected registry
             (base ^ "polling:\n  interval_ms: " ^ lexeme ^ "\n")))
      [
        "0";
        "-1";
        "17.0";
        "1e1";
        "true";
        "' 17'";
        "'17 '";
        "1_7";
        "'1_7'";
        "'0x11'";
        "'17ms'";
        "'$ABSENT_MS'";
        "'prefix$POLL_MS'";
        "99999999999999999999999999999999999999999999999999";
      ];
    List.iter
      (fun field -> ignore (rejected registry (base ^ field)))
      [
        "agent:\n  max_concurrent_agents: 0\n";
        "agent:\n  max_turns: 0\n";
        "agent:\n  max_retry_backoff_ms: 0\n";
        "hooks:\n  timeout_ms: 0\n";
        "codex:\n  read_timeout_ms: 0\n";
        "codex:\n  turn_timeout_ms: 0\n";
      ];
    List.iter
      (fun lexeme ->
        let policy =
          schedule ("codex:\n  stall_timeout_ms: " ^ lexeme ^ "\n")
        in
        match Scheduling_policy.stall policy with
        | Scheduling_policy.Disabled -> ()
        | Scheduling_policy.Silence_limit _ ->
            Alcotest.fail "nonpositive stall enabled")
      [ "0"; "-1"; "'-27'" ]

  let typed_strings () =
    List.iter
      (fun (source, expected) ->
        Alcotest.(check string)
          source expected
          (checked
             (Fields.text
                (Environment.public env ~deny:[ "LINEAR_API_KEY" ] ~secrets:[])
                (value source))))
      [
        ("'$WORK_ROOT'", "repositories");
        ("'$WORK_ROOT/repo'", "$WORK_ROOT/repo");
        ("'${WORK_ROOT}'", "${WORK_ROOT}");
        ("'prefix$WORK_ROOT'", "prefix$WORK_ROOT");
        ( "'https://example.invalid/$WORK_ROOT'",
          "https://example.invalid/$WORK_ROOT" );
      ]

  let name_examples registry () =
    let text =
      "tracker:\n\
      \  kind: linear\n\
      \  active_states: [' TODO ', 'İN PROGRESS', 'ÉTAT']\n\
      \  terminal_states: [' DONE ']\n\
      \  required_labels: [' BUG ', 'Bug', ' ']\n\
      \  provider:\n\
      \    project_slug: fixture-project\n"
    in
    let policy = Config.scheduling (checked_config registry text) in
    Alcotest.(check (list string))
      "Unicode normalized states"
      [ "i̇n progress"; "todo"; "état" ]
      (names (Scheduling_policy.active policy));
    Alcotest.(check (list string))
      "blank label retained" [ ""; "bug" ]
      (names (Scheduling_policy.required_labels policy));
    ignore
      (rejected registry
         "tracker:\n\
         \  kind: linear\n\
         \  active_states: ['Todo']\n\
         \  terminal_states: [' TODO ']\n\
         \  provider:\n\
         \    project_slug: fixture-project\n");
    ignore
      (rejected registry
         "tracker:\n\
         \  kind: linear\n\
         \  provider:\n\
         \    project_slug: fixture-project\n")

  let overrides registry () =
    let settings =
      configured registry
        "agent:\n\
        \  max_concurrent_agents: 11\n\
        \  max_concurrent_agents_by_state:\n\
        \    ' TODO ': 3\n\
        \    'In Progress': '$POLL_MS'\n\
        \    Empty: 0\n\
        \    Negative: -2\n\
        \    Text: nope\n\
        \    Float: 2.0\n"
    in
    let policy = Config.scheduling settings in
    List.iter
      (fun (name, expected) ->
        Alcotest.(check int)
          name expected
          (Scheduling_policy.state_limit policy name))
      [
        ("todo", 3);
        (" TODO ", 3);
        ("IN PROGRESS", 17);
        ("Empty", 11);
        ("Negative", 11);
        ("Text", 11);
        ("Float", 11);
        ("absent", 11);
      ];
    ignore
      (rejected registry
         (base
        ^ "agent:\n\
          \  max_concurrent_agents_by_state:\n\
          \    'Todo': 2\n\
          \    ' TODO ': 3\n"));
    let ignored =
      configured registry
        "agent:\n\
        \  max_concurrent_agents_by_state:\n\
        \    'Todo': 0\n\
        \    ' TODO ': 3\n"
    in
    Alcotest.(check int)
      "ignored invalid alias cannot collide" 3
      (Scheduling_policy.state_limit (Config.scheduling ignored) "todo")

  let environment_examples registry () =
    let bindings =
      [
        ("HOME", "/home/operator");
        ("PATH", "/safe/bin");
        ("LINEAR_API_KEY", "old-secret");
        ("CUSTOM_TOKEN", "custom-secret");
        ("POLLING_INTERVAL_MS", "99");
        ("TMPDIR", "/different/temp");
        ("UNLISTED", "private");
      ]
    in
    let snapshot = environment bindings in
    let settings = configured registry ~environment:snapshot "" in
    Alcotest.(check string)
      "no global numeric environment override" "30000"
      (milliseconds
         (Scheduling_policy.poll_interval (Config.scheduling settings)));
    Alcotest.(check string)
      "default uses injected temp capability" "/host/temp/symphony_workspaces"
      (Absolute_path.display
         (Workspace_settings.root (Config.workspace settings)));
    let custom =
      checked_config_env registry snapshot
        "tracker:\n\
        \  kind: linear\n\
        \  active_states: [Todo]\n\
        \  terminal_states: [Done]\n\
        \  provider:\n\
        \    project_slug: fixture-project\n\
        \    api_key: '$CUSTOM_TOKEN'\n"
    in
    let child = Environment.bindings (Config.child_env custom) in
    Alcotest.(check (option string))
      "allowed PATH" (Some "/safe/bin")
      (List.assoc_opt "PATH" child);
    List.iter
      (fun name ->
        Alcotest.(check (option string)) name None (List.assoc_opt name child))
      [ "LINEAR_API_KEY"; "CUSTOM_TOKEN"; "UNLISTED" ];
    let allowed_secret =
      checked_config_env registry snapshot
        "tracker:\n\
        \  kind: linear\n\
        \  active_states: [Todo]\n\
        \  terminal_states: [Done]\n\
        \  provider:\n\
        \    project_slug: fixture-project\n\
        \    api_key: '$PATH'\n"
    in
    Alcotest.(check (option string))
      "secret denial dominates PATH allowance" None
      (List.assoc_opt "PATH"
         (Environment.bindings (Config.child_env allowed_secret)));
    let fixed = configured registry ~environment:snapshot "" in
    let changed =
      configured registry
        ~environment:
          (environment
             (("LINEAR_API_KEY", "new-secret")
             :: List.remove_assoc "LINEAR_API_KEY" bindings))
        ""
    in
    Alcotest.(check bool)
      "secret change changes semantic config" false
      (Config.equal fixed changed);
    List.iter
      (fun bindings ->
        match rejected registry ~environment:(environment bindings) base with
        | Config_layer.Tracker error ->
            Alcotest.(check bool)
              "missing-secret category" true
              (Tracker_error.category error
              = Tracker_error.Missing_tracker_secret)
        | Config_layer.Workflow _ | Config_layer.Fields _ ->
            Alcotest.fail "missing provider secret had wrong error category")
      [ []; [ ("LINEAR_API_KEY", "") ] ];
    ignore
      (rejected registry ~environment:snapshot
         "tracker:\n\
         \  kind: linear\n\
         \  active_states: [Todo]\n\
         \  terminal_states: [Done]\n\
         \  provider:\n\
         \    project_slug: fixture-project\n\
         \    api_key: '$ABSENT_TOKEN'\n")

  let unknown_keys registry () =
    let original = configured registry "" in
    let extended =
      configured registry "future_extension:\n  opaque: [true, 42]\n"
    in
    Alcotest.(check bool)
      "unknown core keys ignored" true
      (Config.equal original extended);
    let error =
      rejected registry
        "tracker:\n\
        \  kind: unavailable\n\
        \  active_states: [Todo]\n\
        \  terminal_states: [Done]\n"
    in
    match error with
    | Config_layer.Tracker error ->
        Alcotest.(check bool)
          "unsupported adapter category" true
          (Tracker_error.category error = Tracker_error.Unsupported_tracker_kind)
    | Config_layer.Workflow _ | Config_layer.Fields _ ->
        Alcotest.fail "unsupported adapter had wrong error category"

  let policy_examples registry () =
    let first =
      configured registry
        "codex:\n\
        \  turn_sandbox_policy:\n\
        \    type: workspaceWrite\n\
        \    writableRoots: []\n\
        \    networkAccess: false\n\
        \    excludeSlashTmp: true\n\
        \    excludeTmpdirEnvVar: true\n"
    in
    let reordered =
      configured registry
        "codex:\n\
        \  turn_sandbox_policy:\n\
        \    excludeTmpdirEnvVar: true\n\
        \    excludeSlashTmp: true\n\
        \    networkAccess: false\n\
        \    writableRoots: []\n\
        \    type: workspaceWrite\n"
    in
    Alcotest.(check bool)
      "policy object order is irrelevant" true
      (Config.equal first reordered)

  let policy_reference registry () =
    let snapshot =
      environment [ ("LINEAR_API_KEY", "fixture-secret"); ("POLICY", "never") ]
    in
    let direct =
      configured registry ~environment:snapshot
        "codex:\n  approval_policy: never\n"
    in
    let indirect =
      configured registry ~environment:snapshot
        "codex:\n  approval_policy: '$POLICY'\n"
    in
    Alcotest.(check bool)
      "approval policy resolves explicit variable" true
      (Config.equal direct indirect)

  let endpoint_examples registry () =
    let explicit =
      checked_config registry
        "tracker:\n\
        \  kind: linear\n\
        \  active_states: [Todo, 'In Progress']\n\
        \  terminal_states: [Done, Canceled]\n\
        \  provider:\n\
        \    endpoint: https://api.linear.app/graphql\n\
        \    project_slug: fixture-project\n"
    in
    Alcotest.(check bool)
      "documented endpoint default" true
      (Config.equal (configured registry "") explicit);
    ignore
      (rejected registry
         "tracker:\n\
         \  kind: linear\n\
         \  active_states: [Todo]\n\
         \  terminal_states: [Done]\n\
         \  provider:\n\
         \    endpoint: 'https://'\n\
         \    project_slug: fixture-project\n")

  let strict_endpoints registry () =
    let settings endpoint =
      "tracker:\n  kind: linear\n  active_states: [Todo]\n"
      ^ "  terminal_states: [Done]\n  provider:\n"
      ^ Printf.sprintf "    endpoint: %S\n" endpoint
      ^ "    project_slug: fixture-project\n"
    in
    List.iter
      (fun endpoint -> ignore (rejected registry (settings endpoint)))
      [
        "http://host/graphql";
        "https://";
        "https://host:bad/graphql";
        "https://host:-1/graphql";
        "https://host:/graphql";
        "https://host:0/graphql";
        "https://host:65536/graphql";
        "https://host:" ^ String.make 100 '9' ^ "/graphql";
        "https://host\\evil/graphql";
        "https://host/\n/graphql";
        "https://host/%zz";
        "https://host/raw[bracket]";
        "https://host/graphql#fragment";
        "https://user:password@host/graphql";
        "https://[invalid]/graphql";
      ];
    List.iter
      (fun endpoint -> ignore (checked_config registry (settings endpoint)))
      [
        "https://api.linear.app/graphql";
        "HTTPS://EXAMPLE.COM:443/graphql";
        "https://[::1]:443/graphql";
        "https://example.com/g%72aphql?tag=a%20b&x=/?:";
      ]

  let kind_redaction registry () =
    let credential = "fixture-secret-that-must-not-be-printed" in
    let snapshot = environment [ ("LINEAR_API_KEY", credential) ] in
    let error =
      rejected registry ~environment:snapshot
        "tracker:\n\
        \  kind: '$LINEAR_API_KEY'\n\
        \  active_states: [Todo]\n\
        \  terminal_states: [Done]\n"
    in
    let rendered = error_text error in
    Alcotest.(check bool)
      "substituted credential absent" false
      (List.exists
         (String.starts_with ~prefix:credential)
         (String.split_on_char ' ' rendered));
    Alcotest.(check bool)
      "names tracker.kind" true
      (List.exists
         (fun word -> word = "key=tracker.kind:")
         (String.split_on_char ' ' rendered))

  let provider_error registry () =
    let error =
      rejected registry
        "tracker:\n\
        \  kind: linear\n\
        \  active_states: [Todo]\n\
        \  terminal_states: [Done]\n\
        \  provider: []\n"
    in
    match error with
    | Config_layer.Tracker error -> (
        match Diagnostic.site (Tracker_error.diagnostic error) with
        | Diagnostic.Workflow { file = source; key; line = _ } ->
            Alcotest.(check string)
              "selected file"
              (Workflow_path.display file)
              source;
            Alcotest.(check (option string))
              "actual invalid key" (Some "tracker.provider") key
        | Diagnostic.Host _ | Diagnostic.Issue _ | Diagnostic.Protocol _ ->
            Alcotest.fail "provider error omitted workflow source")
    | Config_layer.Workflow _ | Config_layer.Fields _ ->
        Alcotest.fail "adapter-owned provider error had wrong category"

  let ready_matches reload expected =
    match (Config.readiness reload, expected) with
    | Config.Ready, None -> true
    | Config.Blocked error, Some message -> error_text error = message
    | Config.Ready, Some _ | Config.Blocked _, None -> false

  let reload_example registry () =
    let first = configured registry "polling:\n  interval_ms: 17\n" in
    let next = configured registry "polling:\n  interval_ms: 31\n" in
    let error = rejected registry (base ^ "polling:\n  interval_ms: 0\n") in
    let failed = Config.apply (Config.initial first) (Error error) in
    Alcotest.(check bool)
      "last good survives" true
      (Config.equal first (Config.effective failed));
    Alcotest.(check bool)
      "invalid reload gates dispatch" true
      (ready_matches failed (Some (error_text error)));
    let repaired = Config.apply failed (Ok next) in
    Alcotest.(check bool)
      "repair installs new config" true
      (Config.equal next (Config.effective repaired));
    Alcotest.(check bool)
      "repair clears error" true
      (ready_matches repaired None)

  let load_errors registry () =
    let diagnostic =
      Diagnostic.make
        ~site:
          (Diagnostic.Workflow
             { file = Workflow_path.display file; key = None; line = None })
        ~message:"Workflow cannot be read"
        ~remedy:"Create WORKFLOW.md and grant the service read permission"
    in
    let good = configured registry "" in
    let errors =
      [
        Error (Workflow_loader.Missing_file diagnostic);
        Error (Workflow_loader.Read_error diagnostic);
        Ok "---\ntracker: [\n---\nPrompt";
        Ok "---\n- not\n- a\n- mapping\n---\nPrompt";
      ]
    in
    List.iter
      (fun input ->
        match Loader.load input ~file with
        | Ok _ ->
            Alcotest.fail "loader accepted an unreadable or malformed workflow"
        | Error error ->
            let rendered = workflow_error error in
            Alcotest.(check bool)
              "diagnostic names selected workflow" true
              (String.starts_with ~prefix:(Workflow_path.display file) rendered);
            let remedy =
              match List.rev (String.split_on_char ';' rendered) with
              | text :: _ -> String.trim text
              | [] -> ""
            in
            Alcotest.(check bool)
              "diagnostic supplies remedy" true (remedy <> "");
            let error = Config_layer.Workflow error in
            let failed = Config.apply (Config.initial good) (Error error) in
            Alcotest.(check bool)
              "loader failure retains config" true
              (Config.equal good (Config.effective failed));
            Alcotest.(check bool)
              "loader failure remains visible and gates" true
              (ready_matches failed (Some (error_text error))))
      errors

  let tests ~registry =
    [
      Alcotest.test_case "documented defaults and source identity" `Quick
        (defaults registry);
      Alcotest.test_case "local path expansion and workflow anchor" `Quick
        (path_examples registry);
      Alcotest.test_case "env path resolves leading tilde" `Quick
        (env_tilde registry);
      Alcotest.test_case "HOME contents stay literal" `Quick
        (literal_home registry);
      Alcotest.test_case "empty HOME rejected" `Quick (invalid_home registry "");
      Alcotest.test_case "relative HOME rejected" `Quick
        (invalid_home registry "relative/home");
      Alcotest.test_case "trusted commands remain verbatim" `Quick
        (command_examples registry);
      Alcotest.test_case "exact integer coercion and positive bounds" `Quick
        (numeric_examples registry);
      Alcotest.test_case "typed strings resolve only whole-token references"
        `Quick typed_strings;
      Alcotest.test_case "Unicode names disjoint states blank labels" `Quick
        (name_examples registry);
      Alcotest.test_case "state overrides ignore invalid entries" `Quick
        (overrides registry);
      Alcotest.test_case "explicit environment and adapter secret denial" `Quick
        (environment_examples registry);
      Alcotest.test_case "unknown core keys and adapter kind" `Quick
        (unknown_keys registry);
      Alcotest.test_case "semantic policy equality and explicit references"
        `Quick (policy_examples registry);
      Alcotest.test_case "approval policy resolves explicit reference" `Quick
        (policy_reference registry);
      Alcotest.test_case "Linear endpoint default and URI validation" `Quick
        (endpoint_examples registry);
      Alcotest.test_case "Linear endpoint consumes strict URI syntax" `Quick
        (strict_endpoints registry);
      Alcotest.test_case "unsupported adapter kind cannot expose secrets" `Quick
        (kind_redaction registry);
      Alcotest.test_case "provider error names actual workflow key" `Quick
        (provider_error registry);
      Alcotest.test_case "invalid reload preserves config and gates dispatch"
        `Quick (reload_example registry);
      Alcotest.test_case "loader failures name file remedy and preserve config"
        `Quick (load_errors registry);
    ]

  let properties ~registry =
    let open QCheck2.Gen in
    let positive = int_range 1 10000 in
    let history =
      list_size (int_range 0 30)
        (oneof
           [
             map (fun n -> Valid n) positive;
             oneof_list [ Invalid_poll; Invalid_turn; Missing_workflow ];
           ])
    in
    let initial = configured registry "" in
    let failure = rejected registry (base ^ "polling:\n  interval_ms: 0\n") in
    let turn_failure =
      rejected registry (base ^ "codex:\n  turn_timeout_ms: 0\n")
    in
    let missing =
      Config_layer.Workflow
        (Workflow_loader.Missing_file
           (Diagnostic.make
              ~site:
                (Diagnostic.Workflow
                   {
                     file = Workflow_path.display file;
                     key = None;
                     line = None;
                   })
              ~message:"Workflow file missing" ~remedy:"Restore WORKFLOW.md"))
    in
    let model_history events =
      let rec loop actual model = function
        | [] -> true
        | event :: rest ->
            let incoming =
              match event with
              | Valid n ->
                  Ok
                    (configured registry
                       (Printf.sprintf "polling:\n  interval_ms: %d\n" n))
              | Invalid_poll -> Error failure
              | Invalid_turn -> Error turn_failure
              | Missing_workflow -> Error missing
            in
            let actual = Config.apply actual incoming in
            let model =
              Config_model.apply model (Result.map_error error_text incoming)
            in
            Config.equal (Config.effective actual)
              (Config_model.effective model)
            && ready_matches actual (Config_model.latest_error model)
            && loop actual model rest
      in
      loop (Config.initial initial) (Config_model.initial initial) events
    in
    [
      QCheck2.Test.make
        ~name:"reload matches last-good/error model after every load"
        ~print:(QCheck2.Print.list print_load)
        ~count:400 history model_history;
      QCheck2.Test.make ~name:"valid reload is idempotent and clears failure"
        ~print:QCheck2.Print.int ~count:300 positive (fun n ->
          let settings =
            configured registry
              (Printf.sprintf "polling:\n  interval_ms: %d\n" n)
          in
          let reload =
            Config.apply
              (Config.apply (Config.initial initial) (Error failure))
              (Ok settings)
          in
          let repeated = Config.apply reload (Ok settings) in
          Config.equal settings (Config.effective repeated)
          && ready_matches reload None
          && ready_matches repeated None);
      QCheck2.Test.make ~name:"integer spellings agree with known integer value"
        ~print:print_number ~count:400
        (pair positive (oneof_list [ Decimal; Quoted; Hex; Octal ]))
        (fun (n, form) ->
          let lexeme =
            match form with
            | Hex -> Printf.sprintf "0x%x" n
            | Octal -> Printf.sprintf "0o%o" n
            | Quoted -> Printf.sprintf "'+%d'" n
            | Decimal -> string_of_int n
          in
          let settings =
            configured registry ("polling:\n  interval_ms: " ^ lexeme ^ "\n")
          in
          milliseconds
            (Scheduling_policy.poll_interval (Config.scheduling settings))
          = string_of_int n);
      QCheck2.Test.make
        ~name:"expanded relative roots stay anchored to workflow directory"
        ~print:QCheck2.Print.int ~count:300 positive (fun n ->
          let segment = "repo" ^ string_of_int n in
          let environment =
            environment
              [
                ("LINEAR_API_KEY", "fixture-secret"); ("ROOT_SEGMENT", segment);
              ]
          in
          let settings =
            configured registry ~environment
              "workspace:\n  root: './${ROOT_SEGMENT}/../$ROOT_SEGMENT/tail'\n"
          in
          Absolute_path.display
            (Workspace_settings.root (Config.workspace settings))
          = "/srv/symphony/workflows/" ^ segment ^ "/tail");
      QCheck2.Test.make ~name:"state limits match independent list model"
        ~print:(fun (global, aliases, entries) ->
          Printf.sprintf "global=%d aliases=%b entries=%s" global aliases
            (QCheck2.Print.list
               (QCheck2.Print.pair QCheck2.Print.bool QCheck2.Print.int)
               entries))
        ~count:400
        (triple positive bool
           (list_size (int_range 0 10) (pair bool (int_range (-2) 20))))
        (fun (global, aliases, entries) ->
          let entries =
            List.mapi
              (fun index (valid, n) ->
                let name =
                  if aliases then "Todo" ^ String.make index ' '
                  else Printf.sprintf " STATE%d " index
                in
                (name, if valid then Some n else None))
              entries
          in
          let overrides =
            String.concat ""
              (List.map
                 (fun (name, n) ->
                   Printf.sprintf "    '%s': %s\n" name
                     (match n with
                     | Some n -> string_of_int n
                     | None -> "invalid"))
                 entries)
          in
          let extra =
            Printf.sprintf
              "agent:\n\
              \  max_concurrent_agents: %d\n\
              \  max_concurrent_agents_by_state: %s\n"
              global
              (if entries = [] then "{}" else "\n" ^ overrides)
          in
          match
            (Config_model.limits entries, resolve registry (base ^ extra))
          with
          | Error (), Error (Config_layer.Fields _) -> true
          | Ok model, Ok settings ->
              List.for_all
                (fun name ->
                  Scheduling_policy.state_limit
                    (Config.scheduling settings)
                    name
                  = Config_model.state_limit ~global model name)
                ("absent" :: List.map fst entries)
          | Error (), Ok _
          | Ok _, Error _
          | Error (), Error (Config_layer.Workflow _ | Config_layer.Tracker _)
            -> false);
    ]
end
