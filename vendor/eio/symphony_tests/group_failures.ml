module L = Group_failures_low_level
module G = L.Process.Group

let reports = ref []

let checked_spawn ~sw ~cwd ~stdin ~stdout ~stderr ~executable ~argv ~env =
  match
    G.spawn ~sw ~cwd ~stdin ~stdout ~stderr ~executable ~argv ~env
      ~report_cleanup:(fun error -> reports := error :: !reports)
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
        let expected =
          Error
            ( G.Group_signal Unix.EPERM,
              [ G.Leader_signal Unix.EPERM; G.Reap Unix.ECHILD ] )
        in
        check (G.close child = expected) "explicit close lost ordered failures";
        (child, "primary result"))
  in
  check (primary = "primary result") "cleanup replaced callback result";
  let failure =
    Error
      ( G.Group_signal Unix.EPERM,
        [ G.Leader_signal Unix.EPERM; G.Reap Unix.ECHILD ] )
  in
  check (G.close handle = failure) "cleanup permission lost";
  check (G.close handle = failure) "cleanup permission unstable";
  check
    (G.await_exit handle = Ok (G.Signaled Sys.sigkill))
    "stable observed exit was overwritten by reap failure";
  let byte = Bytes.create 1 in
  check
    (Eio.Time.with_timeout_exn env#clock 2. (fun () -> L.read reader byte 0 1)
    = 0)
    "permission failure leaked the direct child";
  check (G.signal handle G.Kill = Ok ()) "closed handle signaled again";
  print_endline
    "PASS: injected Group_signal/Leader_signal/Reap errors retained in order; \
     observed exit remains stable despite reap error; primary result \
     preserved; real direct cleanup/reap completed before fault injection"
