let property_seed = 20261001

let () =
  Alcotest.run ~and_exit:false "Orchestration laws and lifecycle"
    [
      ("scheduler algebra", Scheduler_algebra_test.tests);
      ("ownership", Ownership_test.tests);
      ("launch planning", Run_plan_test.tests);
      ("typed lifecycle", Lifecycle_test.tests);
    ];
  Printf.printf "\nproperty seed: %d\n%!" property_seed;
  if
    QCheck_base_runner.run_tests
      ~rand:(Random.State.make [| property_seed |])
      (Scheduler_algebra_test.properties @ Ownership_test.properties
     @ Run_plan_test.properties @ Lifecycle_test.properties)
    <> 0
  then exit 1
