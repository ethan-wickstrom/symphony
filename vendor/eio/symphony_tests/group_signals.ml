module L = Group_signal_low_level
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

let run env outer cwd null signal script request =
  let reader, writer = L.pipe ~sw:outer in
  Eio.Switch.run (fun sw ->
      let child =
        checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
          ~executable:"/bin/sh" ~argv:[| "sh"; "-c"; script |] ~env:[||]
      in
      Eio_unix.Fd.close writer;
      let byte = Bytes.create 1 in
      check (L.read reader byte 0 1 = 1) "missing ready byte";
      Option.iter
        (fun request -> check (G.signal child request = Ok ()) "signal failed")
        request;
      let observed =
        Eio.Time.with_timeout_exn env#clock 2. (fun () -> G.await_exit child)
      in
      check
        (observed = Ok (G.Signaled signal))
        "WNOWAIT signal convention mismatch";
      check (G.close child = Ok ()) "signal cleanup failed";
      let reaped = L.Fixture.take () in
      check
        (reaped = Some (Unix.WSIGNALED signal))
        "independent waitpid signal mismatch";
      check (G.await_exit child = observed) "reap changed stable observation";
      check
        (Eio.Time.with_timeout_exn env#clock 2. (fun () ->
             L.read reader byte 0 1)
        = 0)
        "signaled child retained pipe");
  Eio_unix.Fd.close reader

let () =
  Eio_posix.run @@ fun env ->
  Eio.Switch.run @@ fun outer ->
  let cwd =
    L.openat ~sw:outer ~mode:0 L.Fs
      (Sys.getenv "SYMPHONY_GROUP_TMPDIR")
      (L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory)
  in
  let null = L.openat ~sw:outer ~mode:0 L.Fs "/dev/null" L.Open_flags.rdwr in
  let running = "printf r; exec /bin/sleep 30" in
  run env outer cwd null Sys.sigterm running (Some G.Term);
  run env outer cwd null Sys.sigkill running (Some G.Kill);
  run env outer cwd null Sys.sigabrt "ulimit -c 0; printf r; kill -ABRT $$" None;
  print_endline
    "PASS: TERM/KILL/ABRT WNOWAIT observations equal independent Unix.waitpid \
     Wsignaled values; stable across reaping; core-file limit zero"
