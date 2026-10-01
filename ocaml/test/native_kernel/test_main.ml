let () =
  Alcotest.run "native workspace"
    [
      ("directory", Native_directory_test.suite);
      ("store", Native_store_test.suite);
      ("process", Native_process_test.tests);
      ("lifetime", Native_lifetime_test.suite);
      ("native io", Native_io_test.tests);
    ]
