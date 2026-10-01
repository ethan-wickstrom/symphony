module L = Group_permission_low_level
module G = L.Process.Group

exception Fixture_cancel

let reports = ref []

let checked_spawn ~sw ~cwd ~stdin ~stdout ~stderr ~executable ~argv ~env =
  match
    G.spawn ~sw ~cwd ~stdin ~stdout ~stderr ~executable ~argv ~env
      ~report_cleanup:(fun error ->
        Eio.Fiber.yield ();
        reports := error :: !reports)
  with
  | Ok child -> child
  | Error (G.Spawn_error error) ->
      raise (Unix.Unix_error (error, "spawn", "fixture"))
  | Error (G.Worker_unavailable message) -> failwith message
  | Error (G.Spawn_cleanup_failed (error, _)) ->
      raise (Unix.Unix_error (error, "spawn", "fixture"))

let check ok message = if not ok then failwith message

let () =
  Eio_posix.run @@ fun env ->
  Eio.Switch.run @@ fun outer ->
  let cwd =
    L.openat ~sw:outer ~mode:0 L.Fs
      (Sys.getenv "SYMPHONY_GROUP_TMPDIR")
      (L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory)
  in
  let null = L.openat ~sw:outer ~mode:0 L.Fs "/dev/null" L.Open_flags.rdwr in
  let reader, writer = L.pipe ~sw:outer in
  let handle, primary =
    Eio.Switch.run (fun sw ->
        let child =
          checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
            ~executable:"/bin/sh"
            ~argv:[| "sh"; "-c"; "printf r; exec /bin/sleep 30" |]
            ~env:[||]
        in
        Eio_unix.Fd.close writer;
        let byte = Bytes.create 1 in
        check (L.read reader byte 0 1 = 1) "missing ready byte";
        check
          (G.signal child G.Term = Error Unix.EPERM)
          "first TERM permission lost";
        check
          (G.signal child G.Kill = Error Unix.EPERM)
          "first KILL permission lost";
        (child, "primary result"))
  in
  check (primary = "primary result") "cleanup replaced callback result";
  let failure = G.close handle in
  let permissions =
    match failure with
    | Error (first, rest) ->
        List.for_all
          (fun cause -> cause = G.Group_signal Unix.EPERM)
          (first :: rest)
    | Ok () -> false
  in
  check permissions "cleanup permission lost";
  check (G.close handle = failure) "cleanup permission unstable";
  check
    (G.await_exit handle = Ok (G.Signaled Sys.sigkill))
    "direct child was not reaped";
  let byte = Bytes.create 1 in
  check
    (Eio.Time.with_timeout_exn env#clock 2. (fun () -> L.read reader byte 0 1)
    = 0)
    "permission failure leaked the direct child";
  check (G.signal handle G.Kill = Ok ()) "closed handle signaled again";
  check (List.length !reports = 1) "repeated close duplicated cleanup reporting";
  Eio_unix.Fd.close reader;
  let reader, writer = L.pipe ~sw:outer in
  let canceled =
    match
      Eio.Switch.run (fun sw ->
          ignore
            (checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
               ~executable:"/bin/sh"
               ~argv:[| "sh"; "-c"; "printf r; exec /bin/sleep 30" |]
               ~env:[||]);
          Eio_unix.Fd.close writer;
          let byte = Bytes.create 1 in
          check (L.read reader byte 0 1 = 1) "canceled child not ready";
          raise Fixture_cancel)
    with
    | () -> false
    | exception Fixture_cancel -> true
  in
  check canceled "cleanup reporting replaced cancellation";
  check (List.length !reports = 2) "cancellation cleanup not reported once";
  check (L.read reader byte 0 1 = 0) "cancellation cleanup leaked child";
  Eio_unix.Fd.close reader;
  let reader, writer = L.pipe ~sw:outer in
  Eio.Switch.run (fun sw ->
      let child =
        checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
          ~executable:"/bin/sh"
          ~argv:[| "sh"; "-c"; "printf r; exec /bin/sleep 30" |]
          ~env:[||]
      in
      Eio_unix.Fd.close writer;
      check (L.read reader byte 0 1 = 1) "concurrent child not ready";
      let first, second =
        Eio.Fiber.pair (fun () -> G.close child) (fun () -> G.close child)
      in
      check
        (first = second && Result.is_error first)
        "concurrent close changed failure";
      check (List.length !reports = 3) "concurrent close duplicated reporting";
      check
        (G.close child = first && List.length !reports = 3)
        "stable close reported again");
  check (L.read reader byte 0 1 = 0) "concurrent cleanup leaked child";
  Eio_unix.Fd.close reader;
  print_endline
    "PASS: first TERM/KILL EPERM retained; callback result preserved; stored \
     Group_signal EPERM stable; direct child killed/reaped and stream drained; \
     repeated/concurrent close and cancellation report exactly once"
