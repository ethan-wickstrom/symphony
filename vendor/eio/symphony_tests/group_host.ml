module L = Eio_posix.Low_level
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

exception Fixture_cancel

let check ok message = if not ok then failwith message
let closed = ref 0
let close_permission = ref 0
let signal_permission = ref 0

let count_close handle =
  let result = G.close handle in
  check (G.close handle = result) "cleanup outcome changed";
  match result with
  | Ok () -> incr closed
  | Error (first, rest) when first = G.Group_signal Unix.EPERM && rest = [] ->
      incr close_permission
  | Error _ -> failwith "unexpected cleanup failure"

let count_signal handle requested =
  match G.signal handle requested with
  | Ok () -> ()
  | Error error when error = Unix.EPERM -> incr signal_permission
  | Error _ -> failwith "unexpected signal failure"

let leader_script =
  "(trap '' TERM; printf 'ready\\n'; exec /bin/sleep 30) & printf 'pid:%s\\n' \
   \"$!\"; exit 7"

let running_script = "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 30"

let read_ready reader =
  let bytes = Bytes.create 128 in
  let buffer = Buffer.create 128 in
  let rec loop () =
    let text = Buffer.contents buffer in
    if
      String.starts_with ~prefix:"ready\n" text
      || List.mem "ready" (String.split_on_char '\n' text)
    then ()
    else
      let got = L.read reader bytes 0 (Bytes.length bytes) in
      check (got > 0) "EOF before descendant readiness";
      Buffer.add_subbytes buffer bytes 0 got;
      loop ()
  in
  loop ()

let drain reader =
  let bytes = Bytes.create 128 in
  let buffer = Buffer.create 128 in
  let rec loop () =
    let got = L.read reader bytes 0 (Bytes.length bytes) in
    if got > 0 then (
      Buffer.add_subbytes buffer bytes 0 got;
      loop ())
  in
  loop ();
  Buffer.contents buffer

let spawn sw cwd null writer script =
  checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
    ~executable:"/bin/sh" ~argv:[| "sh"; "-c"; script |] ~env:[||]

let early_exit env outer cwd null =
  let reader, writer = L.pipe ~sw:outer in
  let handle =
    Eio.Switch.run (fun sw ->
        let child = spawn sw cwd null writer leader_script in
        Eio_unix.Fd.close writer;
        Eio.Time.with_timeout_exn env#clock 2. (fun () -> read_ready reader);
        check (G.await_exit child = Ok (G.Exited 7)) "wrong leader exit";
        check (G.await_exit child = Ok (G.Exited 7)) "unstable observed exit";
        check (G.signal child G.Term = Ok ()) "first TERM failed";
        let term_ignored =
          try
            Eio.Time.with_timeout_exn env#clock 0.02 (fun () ->
                ignore (drain reader));
            false
          with Eio.Time.Timeout -> true
        in
        check term_ignored "descendant unexpectedly obeyed TERM";
        check (G.signal child G.Kill = Ok ()) "first KILL failed";
        count_signal child G.Kill;
        Eio.Time.with_timeout_exn env#clock 2. (fun () -> ignore (drain reader));
        count_close child;
        child)
  in
  check (G.signal handle G.Term = Ok ()) "closed TERM failed";
  check (G.signal handle G.Kill = Ok ()) "closed KILL failed";
  check (G.await_exit handle = Ok (G.Exited 7)) "release changed leader status";
  Eio_unix.Fd.close reader

let release_exit env outer cwd null =
  let reader, writer = L.pipe ~sw:outer in
  let handle =
    Eio.Switch.run (fun sw ->
        let child = spawn sw cwd null writer leader_script in
        Eio_unix.Fd.close writer;
        Eio.Time.with_timeout_exn env#clock 2. (fun () -> read_ready reader);
        check (G.await_exit child = Ok (G.Exited 7)) "release leader exit";
        child)
  in
  count_close handle;
  Eio.Time.with_timeout_exn env#clock 2. (fun () -> ignore (drain reader));
  Eio_unix.Fd.close reader

let cancel env outer cwd null =
  let reader, writer = L.pipe ~sw:outer in
  let canceled =
    try
      Eio.Switch.run (fun sw ->
          let child = spawn sw cwd null writer running_script in
          Eio_unix.Fd.close writer;
          Eio.Time.with_timeout_exn env#clock 2. (fun () -> read_ready reader);
          Eio.Fiber.first
            (fun () -> ignore (G.await_exit child))
            (fun () ->
              Eio.Fiber.yield ();
              raise Fixture_cancel));
      false
    with Fixture_cancel -> true
  in
  check canceled "cancellation changed into another outcome";
  Eio.Time.with_timeout_exn env#clock 2. (fun () -> ignore (drain reader));
  Eio_unix.Fd.close reader

let failed_spawn cwd null =
  let rejected =
    try
      Eio.Switch.run (fun sw ->
          ignore
            (checked_spawn ~sw ~cwd ~stdin:null ~stdout:null ~stderr:null
               ~executable:"/symphony-fixture-does-not-exist"
               ~argv:[| "missing" |] ~env:[||]));
      false
    with Unix.Unix_error (Unix.ENOENT, _, _) -> true
  in
  check rejected "missing executable was accepted"

let startup_cancel env outer cwd null =
  let reader, writer = L.pipe ~sw:outer in
  let canceled =
    match
      Eio.Switch.run (fun sw ->
          Eio.Fiber.fork ~sw (fun () ->
              Eio.Fiber.yield ();
              Eio.Switch.fail sw Fixture_cancel);
          ignore (spawn sw cwd null writer running_script);
          Eio.Fiber.await_cancel ())
    with
    | (_ : unit) -> false
    | exception Fixture_cancel -> true
  in
  Eio_unix.Fd.close writer;
  check canceled "startup cancellation changed outcome";
  Eio.Time.with_timeout_exn env#clock 2. (fun () -> ignore (drain reader));
  Eio_unix.Fd.close reader

let fd_cwd env outer null =
  let original =
    Filename.concat (Sys.getenv "SYMPHONY_GROUP_TMPDIR") "fd-cwd"
  in
  let moved = original ^ "-moved" in
  Unix.mkdir original 0o700;
  Fun.protect
    ~finally:(fun () ->
      Unix.unlink original;
      Unix.rmdir moved)
    (fun () ->
      let flags =
        L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory
      in
      let cwd = L.openat ~sw:outer ~mode:0 L.Fs original flags in
      Unix.rename original moved;
      Unix.symlink "/" original;
      let reader, writer = L.pipe ~sw:outer in
      let output =
        Eio.Switch.run (fun sw ->
            let child =
              checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
                ~executable:"/bin/pwd" ~argv:[| "pwd"; "-P" |] ~env:[||]
            in
            Eio_unix.Fd.close writer;
            let output =
              Eio.Time.with_timeout_exn env#clock 2. (fun () -> drain reader)
            in
            check (G.await_exit child = Ok (G.Exited 0)) "pwd failed";
            output)
      in
      check (String.trim output = moved) "cwd followed the replaced pathname";
      Eio_unix.Fd.close reader;
      Eio_unix.Fd.close cwd)

let () =
  Eio_posix.run @@ fun env ->
  Eio.Switch.run @@ fun outer ->
  let cwd =
    L.openat ~sw:outer ~mode:0 L.Fs
      (Sys.getenv "SYMPHONY_GROUP_TMPDIR")
      (L.Open_flags.( + )
         (L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory)
         L.Open_flags.nofollow)
  in
  let null = L.openat ~sw:outer ~mode:0 L.Fs "/dev/null" L.Open_flags.rdwr in
  for _ = 1 to 1000 do
    early_exit env outer cwd null;
    release_exit env outer cwd null;
    cancel env outer cwd null;
    failed_spawn cwd null;
    startup_cancel env outer cwd null
  done;
  fd_cwd env outer null;
  Printf.printf
    "PASS: 1000 early exits + 1000 group cleanups + 1000 cancellations + 1000 \
     startup cancellations + 1000 failed spawns; %d normal closures, %d \
     conservative EPERM cleanup values, %d conservative EPERM repeated-signal \
     values; stable outcomes and FD cwd\n"
    !closed !close_permission !signal_permission
