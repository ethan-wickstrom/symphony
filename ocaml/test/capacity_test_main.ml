let () =
  Alcotest.run "Native capacity measurements"
    [ Capacity_measurements_test.suite (); Capacity_cycle_test.suite () ]
