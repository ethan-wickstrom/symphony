module F = Core_fixture

let warmup_cycles = 5
let measured_cycles = 100
let max_sessions = 1000
let poll_interval_ms = 10

let checked = function
  | Ok value -> value
  | Error message -> invalid_arg message

let config =
  let base = checked (Absolute_path.parse "/fixture/core") in
  let file = checked (Workflow_path.resolve ~base "WORKFLOW.md") in
  let env =
    checked
      (Environment.of_bindings ~temp_dir:base
         [
           ("LINEAR_API_KEY", "fixture-secret-a");
           ("HOME", "/fixture/home-a");
           ("PATH", "/fixture/bin-a");
         ])
  in
  let source =
    Printf.sprintf
      "---\n\
       tracker:\n\
      \  kind: linear\n\
      \  active_states: [Doing]\n\
      \  terminal_states: [Done]\n\
      \  provider:\n\
      \    project_slug: core-fixture\n\
       polling:\n\
      \  interval_ms: %d\n\
       agent:\n\
      \  max_concurrent_agents: %d\n\
      \  max_concurrent_agents_by_state: {Doing: %d}\n\
       workspace:\n\
      \  root: /fixture/root-a\n\
       hooks:\n\
      \  after_run: finish-a\n\
       codex:\n\
      \  command: agent-a app-server\n\
       ---\n\
       a"
      poll_interval_ms max_sessions max_sessions
  in
  let document =
    match Workflow_document.parse ~file source with
    | Ok value -> value
    | Error
        ( Workflow_document.Parse_error error
        | Workflow_document.Front_matter_not_map error ) ->
        invalid_arg (Diagnostic.render error)
  in
  let config =
    match F.Config.resolve Tracker_fixture.registry ~env ~document with
    | Ok value -> value
    | Error (Config_layer.Tracker error) ->
        invalid_arg (Diagnostic.render (Tracker_error.diagnostic error))
    | Error (Config_layer.Fields errors) ->
        invalid_arg
          (String.concat "\n"
             (List.map Diagnostic.render (Nonempty_list.to_list errors)))
    | Error (Config_layer.Workflow _) -> invalid_arg "capacity workflow failed"
  in
  if
    not
      (Tracker_registry.Contract.equal (F.Config.tracker config)
         (F.Config.tracker (F.config F.A)))
  then invalid_arg "capacity tracker authority differs from A";
  config

let issues ~sessions =
  if not (List.mem sessions [ 1; 10; 100; max_sessions ]) then
    invalid_arg "capacity sessions must be 1, 10, 100 or 1000";
  List.init sessions (fun index ->
      F.issue ~state:"Doing" ~title:"Capacity session"
        ~id:(Printf.sprintf "capacity-%04d" index)
        ~identifier:(Printf.sprintf "CAPACITY-%04d" index)
        ~labels:[ " ready " ] ())
