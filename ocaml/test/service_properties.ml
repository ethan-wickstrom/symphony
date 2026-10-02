open Service_test_support

let property_seed = 20261002

let () =
  Printf.printf "service property seed: %d\n%!" property_seed;
  exit
    (QCheck_base_runner.run_tests
       ~rand:(Random.State.make [| property_seed |])
       (Service_inbox_test.properties @ Service_failure_test.properties
      @ Service_sim_test.properties))
