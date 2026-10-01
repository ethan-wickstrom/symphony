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

let spawn sw cwd null writer =
  checked_spawn ~sw ~cwd ~stdin:null ~stdout:writer ~stderr:writer
    ~executable:"/bin/sh"
    ~argv:[| "sh"; "-c"; "printf r; exec /bin/sleep 30" |]
    ~env:[||]

let read_ready reader =
  let byte = Bytes.create 1 in
  check (L.read reader byte 0 1 = 1) "missing ready byte"

let drained env reader =
  let byte = Bytes.create 1 in
  check
    (Eio.Time.with_timeout_exn env#clock 2. (fun () -> L.read reader byte 0 1)
    = 0)
    "cleanup leaked a child/pipe";
  Eio_unix.Fd.close reader

let cancel_close env outer cwd null =
  let reader, writer = L.pipe ~sw:outer in
  Eio.Switch.run (fun sw ->
      let child = spawn sw cwd null writer in
      Eio_unix.Fd.close writer;
      read_ready reader;
      let canceled =
        Eio.Cancel.sub (fun ctx ->
            Eio.Cancel.cancel ctx Fixture_cancel;
            match G.close child with
            | _ -> false
            | exception Eio.Cancel.Cancelled Fixture_cancel -> true)
      in
      check canceled "public close failed to propagate pending cancellation";
      check (G.close child = Ok ()) "cleanup did not finish before cancellation";
      check
        (G.await_exit child = Ok (G.Signaled Sys.sigkill))
        "cancellation skipped reap");
  drained env reader

let shared_close env outer cwd null =
  let reader, writer = L.pipe ~sw:outer in
  Eio.Switch.run (fun sw ->
      let child = spawn sw cwd null writer in
      Eio_unix.Fd.close writer;
      read_ready reader;
      let first, second =
        Eio.Fiber.pair (fun () -> G.close child) (fun () -> G.close child)
      in
      check
        (first = Ok () && second = first)
        "concurrent cleanup changed result";
      check
        (G.await_exit child = Ok (G.Signaled Sys.sigkill))
        "concurrent cleanup skipped reap");
  drained env reader

let () =
  Eio_posix.run @@ fun env ->
  Eio.Switch.run @@ fun outer ->
  let cwd =
    L.openat ~sw:outer ~mode:0 L.Fs
      (Sys.getenv "SYMPHONY_GROUP_TMPDIR")
      (L.Open_flags.( + ) L.Open_flags.rdonly L.Open_flags.directory)
  in
  let null = L.openat ~sw:outer ~mode:0 L.Fs "/dev/null" L.Open_flags.rdwr in
  for _ = 1 to 1000 do
    cancel_close env outer cwd null;
    shared_close env outer cwd null
  done;
  print_endline
    "PASS: 1000 public-close cancellations propagate after cleanup; 1000 \
     concurrent closes share stable successful completion; children reaped and \
     pipes drained"
