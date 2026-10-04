let () =
  Alcotest.run "Owned Codex protocol"
    [
      ("wire identity", Protocol_id_test.tests);
      ("envelope", Protocol_envelope_test.tests);
      ("codec", Protocol_codec_test.tests);
      Protocol_frame_test.suite ();
      Agent_session_test.suite ();
      Agent_runner_test.suite ();
    ]
