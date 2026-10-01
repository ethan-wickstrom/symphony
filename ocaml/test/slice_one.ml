module Config = Config_layer.Make (Tracker_config)
module Tests = Config_test.Make (Config)

let () =
  let registry =
    match
      Tracker_config.make [ Tracker_config.Entry (module Linear_settings) ]
    with
    | Ok r -> r
    | Error e -> failwith (Diagnostic.render (Tracker_error.diagnostic e))
  in
  let properties =
    Workflow_parser_test.properties @ Template_test.properties
    @ Tests.properties ~registry @ Domain_test.properties
    @ Registry_test.properties @ Workspace_key_test.properties
    @ Workspace_reference_test.properties @ Workspace_policy_test.properties
  in
  let property_cases =
    List.mapi
      (fun i (QCheck2.Test.Test cell as p) ->
        Alcotest.test_case (QCheck2.Test.get_name cell) `Quick (fun () ->
            QCheck2.Test.check_exn ~rand:(Random.State.make [| 20260930; i |]) p))
      properties
  in
  Alcotest.run "Symphony boundaries"
    [
      ("workflow", Workflow_parser_test.tests);
      ("template", Template_test.tests);
      ("configuration", Tests.tests ~registry);
      ("domain", Domain_test.tests);
      ("registry", Registry_test.tests);
      ("workspace keys", Workspace_key_test.tests);
      ("workspace references", Workspace_reference_test.tests);
      ("workspace policy", Workspace_policy_test.tests);
      ("properties", property_cases);
    ]
