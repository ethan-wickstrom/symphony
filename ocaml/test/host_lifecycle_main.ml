let () =
  Printexc.record_backtrace true;
  Alcotest.run "Symphony host lifecycle"
    [
      ("shutdown", Native_shutdown_test.tests);
      ("operator output", Native_output_test.tests);
    ]
