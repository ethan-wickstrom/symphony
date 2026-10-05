let () =
  Printexc.record_backtrace true;
  Alcotest.run "Symphony host lifecycle"
    [
      ("shutdown", Native_shutdown_test.tests);
      ("operator output", Native_output_test.tests);
      ("primary scope", Native_scope_test.tests);
      ("status transport", Native_status_test.tests);
    ]
