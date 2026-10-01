let () =
  Alcotest.run "Public native workspace host"
    [ ("host", Native_host_test.tests) ]
