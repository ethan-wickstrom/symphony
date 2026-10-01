let identity () =
  let original = ref () in
  let calls = ref 0 in
  match
    Native_io.capture (fun () ->
        incr calls;
        original)
  with
  | Ok observed ->
      Alcotest.(check bool) "Success identity" true (observed == original);
      Alcotest.(check int) "Thunk executed once" 1 !calls
  | Error (Native_io.Unix _ | Native_io.Io _) ->
      Alcotest.fail "Successful operation failed"

let unix_failure () =
  match
    Native_io.capture (fun () ->
        raise (Unix.Unix_error (Unix.EACCES, "openat", "secret-path")))
  with
  | Error (Native_io.Unix (error, operation)) ->
      Alcotest.(check bool) "Typed Unix error" true (error = Unix.EACCES);
      Alcotest.(check string)
        "Operation retained without path" "openat" operation
  | Error (Native_io.Io _) | Ok _ ->
      Alcotest.fail "Unix failure taxonomy changed"

let typed_io () =
  let original = Eio.Exn.create (Eio.Fs.E Eio.Fs.Symlink) in
  match original with
  | Eio.Io (error, context) -> (
      match Native_io.capture (fun () -> raise original) with
      | Error (Native_io.Io (observed_error, observed_context)) ->
          Alcotest.(check bool)
            "Typed IO payload retained" true (observed_error == error);
          Alcotest.(check bool)
            "IO context retained" true
            (observed_context == context)
      | Error (Native_io.Unix _) | Ok _ ->
          Alcotest.fail "Typed IO failure was replaced")
  | _ -> Alcotest.fail "Eio did not construct an IO exception"

let worker_sys_error () =
  Eio_posix.run (fun _ ->
      let original = Sys_error "worker-function defect" in
      let traces = Atomic.make [] in
      let outcome =
        Native_outcome.capture (fun () ->
            Native_io.capture (fun () ->
                Eio_unix.run_in_systhread (fun () ->
                    try raise original
                    with exn ->
                      let trace = Printexc.get_raw_backtrace () in
                      Atomic.set traces [ trace ];
                      Printexc.raise_with_backtrace exn trace)))
      in
      match outcome with
      | Native_outcome.Raised (observed, trace) -> (
          Alcotest.(check bool)
            "Worker defect identity retained" true (observed == original);
          match Atomic.get traces with
          | [ expected ] ->
              Alcotest.(check bool)
                "Nonempty worker backtrace" true
                (Printexc.raw_backtrace_length expected > 0);
              Alcotest.(check bool)
                "Original worker backtrace retained" true
                (String.starts_with
                   ~prefix:(Printexc.raw_backtrace_to_string expected)
                   (Printexc.raw_backtrace_to_string trace))
          | [] | _ :: _ -> Alcotest.fail "Worker backtrace was not captured")
      | Native_outcome.Returned _ ->
          Alcotest.fail "Worker Sys_error became an expected failure")

let tests =
  List.map
    (fun (name, test) -> Alcotest.test_case name `Quick test)
    [
      ("success identity and one execution", identity);
      ("Unix error retains operation and discards path", unix_failure);
      ("typed Eio IO retains payload and context", typed_io);
      ("worker Sys_error remains a defect", worker_sys_error);
    ]
