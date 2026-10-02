module Config = Config_layer.Make (Tracker_registry)
module Tests = Config_test.Make (Config)

let () =
  let registry = Tracker_fixture.registry in
  let properties =
    Workflow_parser_test.properties @ Template_test.properties
    @ Tests.properties ~registry @ Domain_test.properties
    @ Registry_test.properties @ Workspace_key_test.properties
    @ Workspace_reference_test.properties @ Workspace_policy_test.properties
    @ Workspace_owner_test.properties @ Clock_test.properties
    @ Issue_batch_test.properties @ Linear_boundary_test.properties
    @ Registry_binding_test.properties @ Linear_omission_test.properties
    @ Linear_pager_test.properties @ Http_codec_test.properties
    @ Linear_tracker_test.properties @ Environment_boundary_test.properties
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
      ("environment quarantine", Environment_boundary_test.tests);
      ("domain", Domain_test.tests);
      ("crypto rejection", Crypto_boundary_test.tests);
      ("issue batches", Issue_batch_test.tests);
      ("Linear boundaries", Linear_boundary_test.tests);
      ("Linear pagination", Linear_pager_test.tests);
      ("Linear reads", Linear_tracker_test.tests);
      ("HTTP codec", Http_codec_test.tests);
      ("clock", Clock_test.tests);
      ("deadlines", Deadline_test.tests);
      ("registry", Registry_test.tests);
      ("frozen tracker bindings", Registry_binding_test.tests);
      ("Linear omissions", Linear_omission_test.tests);
      ("workspace keys", Workspace_key_test.tests);
      ("workspace references", Workspace_reference_test.tests);
      ("workspace owners", Workspace_owner_test.tests);
      ("workspace policy", Workspace_policy_test.tests);
      ("workspace driver", Workspace_driver_test.tests);
      ("workspace hooks", Workspace_hooks_test.tests);
      ("properties", property_cases);
    ]
