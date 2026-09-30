let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

module Provider = struct
  type settings = Json.t

  let kind = "provider-fixture"
  let equal left right = Json.encode left = Json.encode right
  let secret_names _ = []
  let scope _ = checked (Tracker_scope.parse "provider-fixture-scope")

  (* The fixture observes the entire adapter-owned tree through semantic JSON.
     It performs no provider operation and retains no raw production credentials. *)
  let parse ~env:_ ~active:_ ~terminal:_ provider =
    Result.map_error
      (fun message ->
        Tracker_error.make Tracker_error.Invalid_tracker_config
          (Fields.diagnostic ~key:"tracker.provider" message))
      (Fields.json provider)
end

module Config = Config_layer.Make (Tracker_config)

let registry =
  match Tracker_config.make [ Tracker_config.Entry (module Provider) ] with
  | Ok registry -> registry
  | Error error ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))

let file =
  let base = checked (Absolute_path.parse "/fixture/workflows") in
  checked (Workflow_path.resolve ~base "WORKFLOW.md")

let env =
  checked
    (Environment.of_bindings
       ~temp_dir:(checked (Absolute_path.parse "/fixture/temp"))
       [])

let configured provider =
  let source =
    "---\n\
     tracker:\n\
    \  kind: provider-fixture\n\
    \  active_states: [Todo]\n\
    \  terminal_states: [Done]\n" ^ provider ^ "---\n"
  in
  let document =
    match Workflow_document.parse ~file source with
    | Ok document -> document
    | Error
        ( Workflow_document.Parse_error d
        | Workflow_document.Front_matter_not_map d ) ->
        Alcotest.fail (Diagnostic.render d)
  in
  match Config.resolve registry ~env ~document with
  | Ok config -> config
  | Error (Config_layer.Fields errors) ->
      Alcotest.fail
        (String.concat "\n"
           (List.map Diagnostic.render (Nonempty_list.to_list errors)))
  | Error (Config_layer.Tracker error) ->
      Alcotest.fail (Diagnostic.render (Tracker_error.diagnostic error))
  | Error (Config_layer.Workflow _) ->
      Alcotest.fail "parsed document failed to load"

let provider_tree n =
  Printf.sprintf
    "  provider:\n\
    \    future_tree:\n\
    \      opaque: [true, null, 'exact text', {value: %d}]\n"
    n

let forwarding () =
  let first = configured (provider_tree 17) in
  let changed = configured (provider_tree 31) in
  Alcotest.(check bool)
    "unknown nested provider key reaches adapter" false
    (Config.equal first changed);
  Alcotest.(check bool)
    "same tree reaches adapter deterministically" true
    (Config.equal first (configured (provider_tree 17)));
  Alcotest.(check bool)
    "omitted provider defaults to empty object" true
    (Config.equal (configured "") (configured "  provider: {}\n"))

let duplicate_kind () =
  match
    Tracker_config.make
      [
        Tracker_config.Entry (module Provider);
        Tracker_config.Entry (module Provider);
      ]
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "registry accepted duplicate adapter kinds"

let tests =
  [
    Alcotest.test_case "adapter receives unknown provider tree" `Quick
      forwarding;
    Alcotest.test_case "registry kinds are unique" `Quick duplicate_kind;
  ]

let properties =
  [
    QCheck2.Test.make ~name:"provider tree equality follows adapter observation"
      ~count:300
      ~print:QCheck2.Print.(pair int int)
      QCheck2.Gen.(pair (int_range 0 1000) (int_range 0 1000))
      (fun (left, right) ->
        Config.equal
          (configured (provider_tree left))
          (configured (provider_tree right))
        = (left = right));
  ]
