open Service_test_support

let () =
  Alcotest.run "Service effects"
    [
      ("notification slots", Service_inbox_test.tests);
      ("failure boundary", Service_failure_test.tests);
      ("scoped service", Service_sim_test.tests);
      ("owner queries", Service_query_test.tests);
    ]
